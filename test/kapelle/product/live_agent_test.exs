defmodule Kapelle.Product.LiveAgentTest do
  @moduledoc """
  Contract + integration coverage for `Kapelle.Product.LiveAgent` (design
  doc DT-03): offline preflight (BEH-05), catalog-only invocation params
  (BEH-06), the provider-failure -> port-class table (BEH-08), fail-closed
  classification of an unrecognized failure (BEH-09), rejection of an
  invalid live response without persistence (BEH-13), no fallback +
  actually-answering-model attribution (BEH-21), and secrets never
  leaving configuration (BEH-29).

  Every provider interaction goes through a real `LLMChain.run/1` over a
  real `ChatAnthropic` model, with only the HTTP transport stubbed
  (`Req.Test`, wired in via `:product_provider_req_opts` — this module's
  own seam, mirroring `:product_catalog_path`) — so every failure shape
  asserted on here is the actual shape the vendored SDK produces for that
  wire response, not a hand-built double of it (design doc §"Рамки
  red-дизайна", BEH-08's own "в той форме, в которой его отдаёт вендоренный
  SDK").
  """

  use Kapelle.DataCase, async: false

  import Plug.Conn

  alias Kapelle.Product.{Loop, Loops, LiveAgent, Store, View}

  @golden_root "test/support/fixtures/golden"
  @now_iso "2026-09-07T12:00:00Z"

  setup do
    Application.put_env(:kapelle, :product_clock, fn -> @now_iso end)

    on_exit(fn ->
      Application.delete_env(:kapelle, :product_clock)
      Application.delete_env(:kapelle, :product_catalog_path)
      Application.delete_env(:kapelle, :product_provider_req_opts)
    end)

    :ok
  end

  # --- shared fixtures/helpers ---

  defp minimal_view(iteration \\ 0) do
    %View{
      loop_id: "LOOP-TEST",
      idea: %{"id" => "IDEA-001", "title" => "test idea"},
      research_packs: %{iteration => %{"id" => "RP-001"}},
      concept_drafts: %{}
    }
  end

  defp put_catalog_path!(path) do
    Application.put_env(:kapelle, :product_catalog_path, path)
  end

  defp write_catalog!(toml) do
    path =
      Path.join(
        System.tmp_dir!(),
        "live_agent_test_catalog_#{System.unique_integer([:positive])}.toml"
      )

    File.write!(path, toml)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp catalog_toml(opts) do
    model = Keyword.get(opts, :model, "test-model")
    temperature = Keyword.get(opts, :temperature, 0.7)
    max_tokens = Keyword.get(opts, :max_tokens, 1000)

    """
    [[models]]
    provider = "anthropic"
    model = "#{model}"

    [models.params]
    temperature = #{temperature}
    max_tokens = #{max_tokens}
    """
  end

  defp install_default_catalog!(opts \\ []) do
    path = write_catalog!(catalog_toml(opts))
    put_catalog_path!(path)
    "anthropic@" <> Keyword.get(opts, :model, "test-model")
  end

  defp stub_name, do: {__MODULE__, System.unique_integer([:positive])}

  defp put_provider_stub!(fun) do
    name = stub_name()
    Req.Test.stub(name, fun)
    Application.put_env(:kapelle, :product_provider_req_opts, plug: {Req.Test, name})
    name
  end

  defp flunking_stub! do
    put_provider_stub!(fn _conn -> flunk("LiveAgent.produce/3 made a network call") end)
  end

  defp success_stub!(response_text, usage \\ %{"input_tokens" => 12, "output_tokens" => 8}) do
    put_provider_stub!(fn conn ->
      Req.Test.json(conn, %{
        "role" => "assistant",
        "type" => "message",
        "stop_reason" => "end_turn",
        "usage" => usage,
        "content" => [%{"type" => "text", "text" => response_text}]
      })
    end)
  end

  defp capturing_stub!(test_pid, response_text) do
    put_provider_stub!(fn conn ->
      {:ok, raw_body, conn} = read_body(conn)
      send(test_pid, {:captured_request, Jason.decode!(raw_body)})

      Req.Test.json(conn, %{
        "role" => "assistant",
        "type" => "message",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
        "content" => [%{"type" => "text", "text" => response_text}]
      })
    end)
  end

  defp counting_stub!(test_pid, respond) do
    put_provider_stub!(fn conn ->
      send(test_pid, :called)
      respond.(conn)
    end)
  end

  defp valid_research_pack(iteration \\ 0) do
    %{
      "id" => "RP-002",
      "idea_ref" => "idea://IDEA-001",
      "iteration" => iteration,
      "findings" => [],
      "constraints" => [],
      "gaps" => [],
      "brief_for_creator" => "Ship it.",
      "requests_to_creator" => []
    }
  end

  defp produce_researcher(catalog_id, view \\ minimal_view()) do
    LiveAgent.produce(:researcher, 0, %{key: catalog_id, view: view})
  end

  describe "BEH-05: offline preflight distinguishes four causes, none of them touching the network" do
    setup do
      flunking_stub!()
      :ok
    end

    test "a syntactically valid catalog id absent from the catalog is model_not_in_catalog" do
      catalog_id = install_default_catalog!() |> then(fn _ -> "anthropic@does-not-exist" end)

      assert {:error, {:model_not_in_catalog, ^catalog_id}} = produce_researcher(catalog_id)
    end

    test "a catalog entry whose provider has no adapter here is no_adapter_for_provider" do
      path =
        write_catalog!("""
        [[models]]
        provider = "openai"
        model = "gpt-5"

        [models.params]
        temperature = 0.5
        """)

      put_catalog_path!(path)

      assert {:error, {:no_adapter_for_provider, "openai"}} =
               produce_researcher("openai@gpt-5")
    end

    test "a structurally invalid catalog entry is catalog_invalid, on a tmp file that never touches the shared catalog" do
      path =
        write_catalog!("""
        [[models]]
        provider = "anthropic"
        # missing required "model" key
        [models.params]
        temperature = 0.7
        """)

      put_catalog_path!(path)

      assert {:error, {:catalog_invalid, _detail}} = produce_researcher("anthropic@whatever")
    end

    test "a missing catalog file is catalog_unreadable" do
      put_catalog_path!(
        Path.join(System.tmp_dir!(), "does-not-exist-#{System.unique_integer()}.toml")
      )

      assert {:error, {:catalog_unreadable, _detail}} = produce_researcher("anthropic@whatever")
    end

    test "the four reasons are pairwise distinct, not collapsed into one generic failure" do
      catalog_id = install_default_catalog!()

      reasons =
        [
          produce_researcher("anthropic@nope"),
          (fn ->
             path =
               write_catalog!("""
               [[models]]
               provider = "openai"
               model = "gpt-5"
               """)

             put_catalog_path!(path)
             produce_researcher("openai@gpt-5")
           end).(),
          (fn ->
             path =
               write_catalog!("""
               [[models]]
               provider = "anthropic"
               # missing required "model" key
               [models.params]
               temperature = 0.7
               """)

             put_catalog_path!(path)
             produce_researcher("anthropic@whatever")
           end).(),
          (fn ->
             put_catalog_path!(
               Path.join(System.tmp_dir!(), "nope-#{System.unique_integer()}.toml")
             )

             produce_researcher("anthropic@whatever")
           end).()
        ]
        |> Enum.map(fn {:error, {reason, _}} -> reason end)

      assert reasons == [
               :model_not_in_catalog,
               :no_adapter_for_provider,
               :catalog_invalid,
               :catalog_unreadable
             ]

      assert Enum.uniq(reasons) == reasons
      refute catalog_id == nil
    end
  end

  describe "BEH-06: invocation params come from the catalog, not the adapter" do
    test "changing the catalog's params changes the request, with no code change" do
      test_pid = self()
      catalog_id = install_default_catalog!(temperature: 0.11, max_tokens: 111)

      capturing_stub!(test_pid, Jason.encode!(Map.put(valid_research_pack(), "iteration", 0)))

      assert {:ok, _doc, _meta} = produce_researcher(catalog_id)

      assert_receive {:captured_request, body}
      assert body["temperature"] == 0.11
      assert body["max_tokens"] == 111
      assert body["model"] == "test-model"

      # Same catalog id, same adapter code — only the catalog file changes.
      catalog_id = install_default_catalog!(temperature: 0.42, max_tokens: 4242)
      capturing_stub!(test_pid, Jason.encode!(Map.put(valid_research_pack(), "iteration", 0)))

      assert {:ok, _doc, _meta} = produce_researcher(catalog_id)

      assert_receive {:captured_request, body}
      assert body["temperature"] == 0.42
      assert body["max_tokens"] == 4242
    end
  end

  describe "BEH-08: provider failure class maps to port class, on the real langchain error shapes" do
    setup do
      catalog_id = install_default_catalog!()
      %{catalog_id: catalog_id}
    end

    test "a connection failure is :infrastructure", %{catalog_id: catalog_id} do
      put_provider_stub!(fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, {:infrastructure, {:provider_error, _type, _msg}}} =
               produce_researcher(catalog_id)
    end

    test "a response timeout is :infrastructure", %{catalog_id: catalog_id} do
      put_provider_stub!(fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, {:infrastructure, {:provider_error, "timeout", _msg}}} =
               produce_researcher(catalog_id)
    end

    test "temporary provider unavailability (529 Overloaded) is :infrastructure", %{
      catalog_id: catalog_id
    } do
      put_provider_stub!(fn conn -> conn |> put_status(529) |> Req.Test.json(%{}) end)

      assert {:error, {:infrastructure, {:provider_error, "overloaded", _msg}}} =
               produce_researcher(catalog_id)
    end

    test "temporary provider unavailability (502/503/504) is :infrastructure", %{
      catalog_id: catalog_id
    } do
      for status <- [502, 503, 504] do
        put_provider_stub!(fn conn ->
          conn |> put_status(status) |> Req.Test.json(%{"type" => "error"})
        end)

        assert {:error, {:infrastructure, {:provider_error, _type, _msg}}} =
                 produce_researcher(catalog_id)
      end
    end

    test "a missing authorization key (401) is a configuration failure, not :domain/:infrastructure",
         %{catalog_id: catalog_id} do
      put_provider_stub!(fn conn ->
        conn
        |> put_status(401)
        |> Req.Test.json(%{
          "type" => "error",
          "error" => %{"type" => "authentication_error", "message" => "missing x-api-key"}
        })
      end)

      assert {:error, {:provider_auth_failed, _type, _msg}} = produce_researcher(catalog_id)
    end

    test "an invalid authorization key (401) is a configuration failure", %{
      catalog_id: catalog_id
    } do
      put_provider_stub!(fn conn ->
        conn
        |> put_status(401)
        |> Req.Test.json(%{
          "type" => "error",
          "error" => %{"type" => "authentication_error", "message" => "invalid x-api-key"}
        })
      end)

      assert {:error, {:provider_auth_failed, _type, _msg}} = produce_researcher(catalog_id)
    end

    test "a revoked authorization key (403) is a configuration failure, classified by status ahead of langchain's own unexpected_response type",
         %{catalog_id: catalog_id} do
      put_provider_stub!(fn conn ->
        conn
        |> put_status(403)
        |> Req.Test.json(%{"type" => "error", "error" => %{"message" => "revoked key"}})
      end)

      assert {:error, {:provider_auth_failed, _type, _msg}} = produce_researcher(catalog_id)
    end

    test "content-based provider refusal (HTTP 400) is :domain", %{catalog_id: catalog_id} do
      put_provider_stub!(fn conn ->
        conn
        |> put_status(400)
        |> Req.Test.json(%{"type" => "error", "error" => %{"message" => "bad request"}})
      end)

      assert {:error, {:domain, {:provider_error, _type, _msg}}} = produce_researcher(catalog_id)
    end

    test "content-based provider refusal (invalid_request_error type, 200 status body-level error) is :domain",
         %{catalog_id: catalog_id} do
      put_provider_stub!(fn conn ->
        Req.Test.json(conn, %{
          "type" => "error",
          "error" => %{"type" => "invalid_request_error", "message" => "prompt too long"}
        })
      end)

      assert {:error, {:domain, {:provider_error, "invalid_request_error", _msg}}} =
               produce_researcher(catalog_id)
    end

    test "the configuration-failure class is distinct from all three failure() classes", %{
      catalog_id: catalog_id
    } do
      put_provider_stub!(fn conn -> conn |> put_status(401) |> Req.Test.json(%{}) end)

      assert {:error, {reason, _, _}} = produce_researcher(catalog_id)
      assert reason == :provider_auth_failed
      refute reason in [:infrastructure, :domain, :invalid_artifact]
    end
  end

  describe "BEH-09: an unrecognized provider failure classifies fail-closed" do
    setup do
      %{catalog_id: install_default_catalog!()}
    end

    test "an unknown error type with no recoverable transport or status is unclassified, not :infrastructure",
         %{catalog_id: catalog_id} do
      put_provider_stub!(fn conn ->
        Req.Test.json(conn, %{
          "type" => "error",
          "error" => %{"type" => "brand_new_provider_error", "message" => "who knows"}
        })
      end)

      assert {:error, {:unclassified_provider_failure, "brand_new_provider_error"}} =
               produce_researcher(catalog_id)
    end

    test "an exception raised inside the SDK's own transport does not crash the adapter", %{
      catalog_id: catalog_id
    } do
      put_provider_stub!(fn _conn -> raise "boom, simulated SDK-internal exception" end)

      assert {:error, {:unclassified_provider_failure, _type}} = produce_researcher(catalog_id)
    end
  end

  describe "BEH-13: a response that fails validation is rejected and never persisted" do
    setup do
      %{catalog_id: install_default_catalog!()}
    end

    test "unparseable text (not StrictParse's expected shape) is invalid_artifact, tagged parse_failed",
         %{catalog_id: catalog_id} do
      success_stub!("this is not json or yaml { at all")

      assert {:error, {:invalid_artifact, {:parse_failed, _}}} = produce_researcher(catalog_id)
    end

    test "an empty response is invalid_artifact, tagged parse_failed", %{catalog_id: catalog_id} do
      success_stub!("")

      assert {:error, {:invalid_artifact, {:parse_failed, _}}} = produce_researcher(catalog_id)
    end

    test "a truncated/unclosed JSON response is invalid_artifact, tagged parse_failed", %{
      catalog_id: catalog_id
    } do
      success_stub!(~s({"id": "RP-001", "iteration": 0))

      assert {:error, {:invalid_artifact, {:parse_failed, _}}} = produce_researcher(catalog_id)
    end

    test "a structurally valid but semantically wrong document is invalid_artifact, tagged schema_invalid",
         %{catalog_id: catalog_id} do
      bad = Map.put(valid_research_pack(), "iteration", "not-a-number")
      success_stub!(Jason.encode!(bad))

      assert {:error, {:invalid_artifact, {:schema_invalid, _}}} = produce_researcher(catalog_id)
    end

    test "a truncated document missing required fields is invalid_artifact, tagged schema_invalid",
         %{catalog_id: catalog_id} do
      success_stub!(Jason.encode!(%{"id" => "RP-001"}))

      assert {:error, {:invalid_artifact, {:schema_invalid, _}}} = produce_researcher(catalog_id)
    end

    test "an invalid live response leaves the loop's stored artifacts and state projection untouched" do
      catalog_id = install_default_catalog!()
      success_stub!(Jason.encode!(%{"id" => "RP-001"}))

      loop_id = "LOOP-#{System.unique_integer([:positive])}"

      {:ok, _row} =
        Loop.start(idea_yaml(),
          loop_id: loop_id,
          proposal_id: "PP-001",
          exchange_log_id: "XL-001",
          max_iterations: 1,
          agent: "model:" <> catalog_id,
          now_iso: @now_iso
        )

      artifacts_before = Store.all(loop_id)
      state_before = Loops.get!(loop_id).latest_state

      assert %{discard: 0} = Oban.drain_queue(queue: :product, with_recursion: true)

      loop = Loops.get!(loop_id)
      assert loop.status == "failed"
      assert loop.stop_reason =~ "invalid_artifact"

      assert Store.all(loop_id) == artifacts_before
      assert loop.latest_state == state_before
    end
  end

  describe "BEH-21: no fallback chain — attribution names the model that actually answered" do
    test "a failing call is not retried against the catalog entry's declared fallback" do
      test_pid = self()

      path =
        write_catalog!("""
        [[models]]
        provider = "anthropic"
        model = "primary-model"
        fallback = ["anthropic@backup-model"]

        [models.params]
        temperature = 0.7

        [[models]]
        provider = "anthropic"
        model = "backup-model"

        [models.params]
        temperature = 0.7
        """)

      put_catalog_path!(path)

      counting_stub!(test_pid, fn conn ->
        conn |> put_status(401) |> Req.Test.json(%{})
      end)

      assert {:error, {:provider_auth_failed, _, _}} =
               produce_researcher("anthropic@primary-model")

      assert_received :called
      refute_received :called
    end

    test "call_meta and the stamped provenance both name the entry actually invoked" do
      catalog_id = install_default_catalog!(model: "primary-model")
      success_stub!(Jason.encode!(valid_research_pack()))

      assert {:ok, doc, call_meta} = produce_researcher(catalog_id)

      assert call_meta.model_id == catalog_id
      assert doc["produced_by"]["model"] == catalog_id
      assert doc["produced_by"]["kind"] == "agent"
      assert doc["produced_by"]["id"] == "researcher"
      assert doc["produced_by"]["prompt_version"] == "researcher/v1"
    end
  end

  describe "BEH-29: secrets never leave configuration" do
    setup do
      previous_key = Application.get_env(:langchain, :anthropic_key)
      marker = "sk-ant-SECRET-MARKER-#{System.unique_integer([:positive])}"
      Application.put_env(:langchain, :anthropic_key, marker)

      on_exit(fn ->
        if previous_key do
          Application.put_env(:langchain, :anthropic_key, previous_key)
        else
          Application.delete_env(:langchain, :anthropic_key)
        end
      end)

      %{marker: marker, catalog_id: install_default_catalog!()}
    end

    test "an authorization failure never surfaces the key value in the adapter's own result", %{
      marker: marker,
      catalog_id: catalog_id
    } do
      put_provider_stub!(fn conn -> conn |> put_status(401) |> Req.Test.json(%{}) end)

      result = produce_researcher(catalog_id)

      assert {:error, {:provider_auth_failed, _, _}} = result
      refute inspect(result) =~ marker
    end

    test "a successful call's result carries no trace of the key", %{
      marker: marker,
      catalog_id: catalog_id
    } do
      success_stub!(Jason.encode!(valid_research_pack()))

      result = produce_researcher(catalog_id)

      assert {:ok, _doc, _meta} = result
      refute inspect(result) =~ marker
    end

    test "the key never reaches stop_reason or the run verdict through a full loop's auth failure",
         %{
           marker: marker
         } do
      catalog_id = install_default_catalog!()
      put_provider_stub!(fn conn -> conn |> put_status(401) |> Req.Test.json(%{}) end)

      loop_id = "LOOP-#{System.unique_integer([:positive])}"

      {:ok, _row} =
        Loop.start(idea_yaml(),
          loop_id: loop_id,
          proposal_id: "PP-001",
          exchange_log_id: "XL-001",
          max_iterations: 1,
          agent: "model:" <> catalog_id,
          now_iso: @now_iso
        )

      Oban.drain_queue(queue: :product, with_recursion: true)

      loop = Loops.get!(loop_id)
      refute loop.stop_reason =~ marker
      refute inspect(loop) =~ marker

      assert {:ok, verdict} = Kapelle.Product.RunVerdict.for_loop(loop_id)
      refute inspect(verdict) =~ marker
    end
  end

  defp idea_yaml, do: File.read!(Path.join([@golden_root, "happy", "workspace", "idea.yaml"]))
end
