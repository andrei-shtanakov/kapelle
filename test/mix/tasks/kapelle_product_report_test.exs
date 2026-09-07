defmodule Mix.Tasks.Kapelle.Product.ReportTest do
  @moduledoc """
  The rendering half of "cost and interventions are visible per run"
  (design doc §9.3): what an operator actually reads. Driven by a real
  golden run rather than a hand-built struct, so the block under test is
  the one a real loop produces.
  """

  use Kapelle.DataCase, async: false
  use Oban.Testing, repo: Kapelle.Repo

  import Ecto.Query, only: [from: 2]
  import Plug.Conn, only: [put_status: 2]

  alias Kapelle.Product.{FixtureAgent, Loop, RunVerdict, StrictParse}
  alias Kapelle.Product.Records.{AgentCallRow, ArtifactRow, LoopRow}
  alias Mix.Tasks.Kapelle.Product.Report

  @workspace "test/support/fixtures/golden/human_waiver/workspace"
  @now_iso "2026-08-12T18:00:00Z"

  setup do
    Application.put_env(:kapelle, :product_clock, fn -> @now_iso end)

    on_exit(fn ->
      Application.delete_env(:kapelle, :product_clock)
      Application.delete_env(:kapelle, :product_catalog_path)
      Application.delete_env(:kapelle, :product_provider_req_opts)
    end)

    :ok
  end

  test "the printed block keeps the axes apart and refuses to print a measured-looking zero" do
    loop_id = run_waiver_loop!()

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)
    output = Report.format(verdict)

    # Two axes, two lines — never one rolled-up verdict.
    assert output =~ "product: pass"
    assert output =~ "harness: pass"

    # The note is printed even though it costs the axis nothing: an
    # operator must be able to see that no provider was ever called.
    assert output =~ "cost_not_applicable (info)"

    # An inapplicable cost says so instead of printing 0.
    assert output =~ "tokens:             not applicable (fixture-backed agents)"
    refute output =~ "tokens:             0"

    # The human act that carried this loop is named, not just counted.
    assert output =~ "waivers:            1 (concept-draft://CD-002)"
    assert output =~ "iterations:         2 / 2"
  end

  test "the three token states read differently: not applicable, a measured zero, a lost figure" do
    # Hand-built on purpose: two of the three states cannot occur until a
    # real provider adapter exists (#50), and the distinction between them
    # is exactly what must not rot in the meantime. `n/a` is not `0`, and
    # neither is a figure the provider owed us and never sent.
    assert Report.format(verdict_with_tokens(nil, :not_applicable)) =~
             "tokens:             not applicable (fixture-backed agents)"

    assert Report.format(verdict_with_tokens(0, nil)) =~ "tokens:             0"

    assert Report.format(verdict_with_tokens(nil, :not_instrumented)) =~
             "tokens:             not instrumented"
  end

  test "a stuck run is legible in the block: the executing row and its orphan status are printed" do
    loop_id = run_waiver_loop!()
    strand_job!(loop_id)

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)
    output = Report.format(verdict)

    # Both facts the verdict computes about in-flight work reach the reader:
    # without them a stalled run and a finished one print the same cost block.
    assert output =~ "executing:          1"
    assert output =~ "orphaned:           1"
    assert output =~ "jobs_orphaned (fail)"
  end

  test "the agent line distinguishes a fixture run from a live one, consistently with the printed cost state (BEH-22)" do
    fixture_output =
      Report.format(verdict_with_tokens(nil, :not_applicable, "fixture:LOOP-A"))

    live_output = Report.format(verdict_with_tokens(42, nil, "model:anthropic@claude-x"))

    assert fixture_output =~ "agent:   fixture:LOOP-A"
    assert fixture_output =~ "tokens:             not applicable (fixture-backed agents)"

    assert live_output =~ "agent:   model:anthropic@claude-x"
    assert live_output =~ "tokens:             42"

    refute fixture_output == live_output
  end

  test "a real live-scheme loop's configured address is what reaches the printed agent line, not a stand-in (BEH-22)" do
    catalog_id = install_default_catalog!()

    research_pack = %{
      "id" => "RP-002",
      "idea_ref" => "idea://IDEA-001",
      "iteration" => 0,
      "findings" => [],
      "constraints" => [],
      "gaps" => [],
      "brief_for_creator" => "Ship it.",
      "requests_to_creator" => []
    }

    success_stub!(%{
      "role" => "assistant",
      "type" => "message",
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 7, "output_tokens" => 3},
      "content" => [%{"type" => "text", "text" => Jason.encode!(research_pack)}]
    })

    loop_id = "LOOP-LIVE-#{System.unique_integer([:positive])}"

    {:ok, _row} =
      Loop.start(File.read!(Path.join(@workspace, "idea.yaml")),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 1,
        agent: "model:" <> catalog_id,
        now_iso: @now_iso
      )

    Oban.drain_queue(queue: :product, with_recursion: true)

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)
    output = Report.format(verdict)

    # The line comes from `RunVerdict.build/1`'s own `loop.agent` read, not
    # from a hand-built verdict — the same wiring a live run actually uses.
    assert output =~ "agent:   model:#{catalog_id}"
  end

  test "a printed report never contains a provider key value, whole or fragmented (BEH-23)" do
    marker = "sk-ant-SECRET-MARKER-#{System.unique_integer([:positive])}"
    previous_key = Application.get_env(:langchain, :anthropic_key)
    Application.put_env(:langchain, :anthropic_key, marker)

    on_exit(fn ->
      if previous_key do
        Application.put_env(:langchain, :anthropic_key, previous_key)
      else
        Application.delete_env(:langchain, :anthropic_key)
      end
    end)

    loop_id = run_waiver_loop!()

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)
    output = Report.format(verdict)

    refute output =~ marker
  end

  test "the key never reaches the printed report through a live loop's own auth failure (BEH-23)" do
    marker = "sk-ant-SECRET-MARKER-#{System.unique_integer([:positive])}"
    previous_key = Application.get_env(:langchain, :anthropic_key)
    Application.put_env(:langchain, :anthropic_key, marker)

    on_exit(fn ->
      if previous_key do
        Application.put_env(:langchain, :anthropic_key, previous_key)
      else
        Application.delete_env(:langchain, :anthropic_key)
      end
    end)

    catalog_id = install_default_catalog!()
    put_provider_stub!(fn conn -> conn |> put_status(401) |> Req.Test.json(%{}) end)

    loop_id = "LOOP-AUTHFAIL-#{System.unique_integer([:positive])}"

    {:ok, _row} =
      Loop.start(File.read!(Path.join(@workspace, "idea.yaml")),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 1,
        agent: "model:" <> catalog_id,
        now_iso: @now_iso
      )

    Oban.drain_queue(queue: :product, with_recursion: true)

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)
    output = Report.format(verdict)

    refute output =~ marker
  end

  test "reading a loop's report leaves every table it touches unchanged (BEH-23)" do
    loop_id = run_waiver_loop!()

    before_snapshot = snapshot_tables(loop_id)
    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)
    Report.format(verdict)
    after_snapshot = snapshot_tables(loop_id)

    assert before_snapshot == after_snapshot
  end

  test "the task mutes Oban before booting: looking at a loop cannot run it" do
    config = Application.fetch_env!(:kapelle, Oban)
    read_only = Report.read_only_oban(config)

    # No queue can pick this loop's jobs up, no plugin can move them — the
    # read-only promise `RunVerdict` makes survives its own CLI wrapper.
    assert read_only[:queues] == false
    assert read_only[:plugins] == false
    assert read_only[:repo] == config[:repo]
  end

  # One of the loop's jobs left in `executing` long enough to be orphaned —
  # what a crashed node leaves behind with no Lifeline configured.
  defp strand_job!(loop_id) do
    job =
      Repo.one!(
        from(j in Oban.Job,
          where: fragment("? ->> 'loop_id' = ?", j.args, ^loop_id),
          order_by: [asc: j.id],
          limit: 1
        )
      )

    {1, _} =
      Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
        set: [
          state: "executing",
          attempted_at: NaiveDateTime.add(NaiveDateTime.utc_now(), -2 * 60 * 60),
          completed_at: nil
        ]
      )
  end

  defp run_waiver_loop! do
    loop_id = "LOOP-001"

    script =
      Map.new(docs_for("rp-*.yaml", :researcher) ++ docs_for("cd-*.yaml", :creator))

    :ok = FixtureAgent.install_script!(loop_id, script)

    {:ok, _row} =
      Loop.start(File.read!(Path.join(@workspace, "idea.yaml")),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 2,
        agent: "fixture:" <> loop_id,
        now_iso: @now_iso
      )

    assert %{discard: 0, failure: 0} = Oban.drain_queue(queue: :product, with_recursion: true)

    loop_id
  end

  defp docs_for(glob, role) do
    @workspace
    |> Path.join(glob)
    |> Path.wildcard()
    |> Enum.map(fn path ->
      {:ok, doc} = path |> File.read!() |> StrictParse.parse()
      {{role, doc["iteration"]}, doc}
    end)
  end

  defp snapshot_tables(loop_id) do
    %{
      loop:
        Repo.one(
          from(l in LoopRow, where: l.loop_id == ^loop_id, select: {l.status, l.stop_reason})
        ),
      artifacts: Repo.aggregate(from(a in ArtifactRow, where: a.loop_id == ^loop_id), :count),
      agent_calls: Repo.aggregate(from(c in AgentCallRow, where: c.loop_id == ^loop_id), :count),
      jobs:
        Repo.all(
          from(j in Oban.Job,
            where: fragment("? ->> 'loop_id' = ?", j.args, ^loop_id),
            select: {j.state, j.attempt}
          )
        )
    }
  end

  # Minimal live-scheme catalog + stubbed transport, mirroring
  # `Kapelle.Product.LiveAgentTest`'s own fixtures: enough to drive a real
  # `Loop.start` over `model:<catalog_id>` without a network call, so the
  # agent line and the secret-leak guarantee are proven against the actual
  # `RunVerdict.build/1` wiring rather than a hand-built struct.
  defp install_default_catalog! do
    path =
      Path.join(
        System.tmp_dir!(),
        "product_report_test_catalog_#{System.unique_integer([:positive])}.toml"
      )

    File.write!(path, """
    [[models]]
    provider = "anthropic"
    model = "test-model"

    [models.params]
    temperature = 0.7
    max_tokens = 1000
    """)

    on_exit(fn -> File.rm(path) end)
    Application.put_env(:kapelle, :product_catalog_path, path)
    "anthropic@test-model"
  end

  defp put_provider_stub!(fun) do
    name = {__MODULE__, System.unique_integer([:positive])}
    Req.Test.stub(name, fun)
    Application.put_env(:kapelle, :product_provider_req_opts, plug: {Req.Test, name})
    name
  end

  defp success_stub!(response_body) do
    put_provider_stub!(fn conn -> Req.Test.json(conn, response_body) end)
  end

  defp verdict_with_tokens(tokens, unavailable, agent \\ "fixture:LOOP-FMT") do
    %RunVerdict{
      loop_id: "LOOP-FMT",
      agent: agent,
      product: :pass,
      product_reason: "rendering fixture",
      harness: :pass,
      harness_findings: [],
      cost: %{
        iterations_used: 1,
        max_iterations: 2,
        stage_jobs: 3,
        attempts: 3,
        retries: 0,
        discarded_jobs: 0,
        cancelled_jobs: 0,
        executing_jobs: 0,
        orphaned_jobs: 0,
        artifact_revisions: 4,
        wall_ms: 10,
        tokens: tokens,
        tokens_unavailable: unavailable
      },
      interventions: %{holds: 0, resumes: 0, resume_refs: [], waivers: 0, waiver_refs: []}
    }
  end
end
