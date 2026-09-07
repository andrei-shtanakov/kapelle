defmodule Kapelle.Task004RedTest do
  @moduledoc """
  RED test for TASK-004 (spec/real-llm-provider-adapters-20260907-tasks.md,
  DT-04, BEH-12): a live stage worker call that hangs past the declared
  upper wait boundary (Q-08, set via
  `Application.put_env(:kapelle, :product_agent_timeout_ms, …)`) must be
  cut off at that boundary and classified `:infrastructure` (retryable),
  not simply awaited until the provider double eventually answers.

  Today `Kapelle.Product.LiveAgent.call_model/3` has no timeout seam at
  all: it runs `LLMChain.run/1` to completion however long the transport
  takes. So a stage worker whose provider double merely answers slowly —
  well under any real network timeout, let alone the design's own
  default 120s — still completes successfully instead of failing closed
  and retryable. This models a provider double that answers after 300ms
  while the loop's own configured wait boundary is 30ms, and asserts the
  boundary is actually enforced: the drained job errors (`failure: 1`,
  still retryable — never `discard`/`cancelled`), and no research-pack
  artifact from the belated response is ever stored.
  """

  use Kapelle.DataCase, async: false
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Product.{Loop, Loops, Store}

  @golden_root "test/support/fixtures/golden"
  @now_iso "2026-09-07T12:00:00Z"

  setup do
    Application.put_env(:kapelle, :product_clock, fn -> @now_iso end)
    Application.put_env(:kapelle, :product_agent_timeout_ms, 30)

    on_exit(fn ->
      Application.delete_env(:kapelle, :product_clock)
      Application.delete_env(:kapelle, :product_agent_timeout_ms)
      Application.delete_env(:kapelle, :product_catalog_path)
      Application.delete_env(:kapelle, :product_provider_req_opts)
    end)

    :ok
  end

  defp write_catalog!(toml) do
    path =
      Path.join(
        System.tmp_dir!(),
        "task_004_red_catalog_#{System.unique_integer([:positive])}.toml"
      )

    File.write!(path, toml)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp install_default_catalog! do
    path =
      write_catalog!("""
      [[models]]
      provider = "anthropic"
      model = "test-model"

      [models.params]
      temperature = 0.7
      max_tokens = 1000
      """)

    Application.put_env(:kapelle, :product_catalog_path, path)
    "anthropic@test-model"
  end

  # Answers well past the loop's own 30ms wait boundary (still far below
  # the design's default 120s — Q-08's own instruction not to wait out
  # the real default) with an otherwise perfectly valid research pack, so
  # a passing run today would prove nothing beyond "slow is fine".
  defp slow_success_stub! do
    name = {__MODULE__, System.unique_integer([:positive])}

    Req.Test.stub(name, fn conn ->
      Process.sleep(300)

      Req.Test.json(conn, %{
        "role" => "assistant",
        "type" => "message",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 12, "output_tokens" => 8},
        "content" => [
          %{
            "type" => "text",
            "text" =>
              Jason.encode!(%{
                "id" => "RP-012",
                "idea_ref" => "idea://IDEA-001",
                "proposal_ref" => "proposal://PP-001",
                "iteration" => 0,
                "findings" => [],
                "constraints" => [],
                "gaps" => [],
                "brief_for_creator" => "Ship it.",
                "requests_to_creator" => []
              })
          }
        ]
      })
    end)

    Application.put_env(:kapelle, :product_provider_req_opts, plug: {Req.Test, name})
  end

  defp idea_yaml, do: File.read!(Path.join([@golden_root, "happy", "workspace", "idea.yaml"]))

  test "BEH-12: a live stage worker call past the configured wait boundary is cut off and classified a retryable infrastructure failure, not awaited to completion" do
    catalog_id = install_default_catalog!()
    slow_success_stub!()

    loop_id = "LOOP-TASK-004-BEH-12"

    {:ok, _row} =
      Loop.start(idea_yaml(),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 1,
        agent: "model:" <> catalog_id,
        now_iso: @now_iso
      )

    stored_before = Store.all(loop_id)

    # Only the research job — not its own recursive follow-on — is
    # relevant here: BEH-12 is about the one call that hangs, not about
    # whatever the loop does afterward.
    assert %{discard: 0, failure: 1, success: 0} = Oban.drain_queue(queue: :product)

    # A cut-off call must never let the belated response through to
    # persistence — the boundary is a hard cutoff, not a slow-path retry
    # that still lands the artifact once the double finally answers.
    assert Store.all(loop_id) == stored_before
    assert Loops.get!(loop_id).status == "running"
  end
end
