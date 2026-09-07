defmodule Kapelle.Product.LiveRunSmokeTest do
  @moduledoc """
  DT-09 (design doc §"Механика опт-ина", Q-08): the sole owner of the
  opt-in live-provider run, gated behind `@moduletag :live_product_run`
  (excluded by default — `test/test_helper.exs`).

  Two scenarios, both `verification: manual` in the acceptance doc — an
  owner runs this file once against a real provider and attaches the
  output as evidence, because a real Anthropic key and real spend are not
  things an automated default suite gets to have (BEH-25):

  - **BEH-26** (AC-21): with no `ANTHROPIC_API_KEY`, `setup_all` refuses
    every test in this file immediately — before any test body, hence
    before any network call — naming the missing env var by name and
    never printing its (absent) value. A silent skip would not satisfy
    this: the run has to fail loudly, not report green by omission.
  - **BEH-27** (AC-22): with a real key, the full product loop — the same
    `Loop.start/2` + Oban `:product` queue path `e2e_happy_test.exs`
    exercises against the fixture double — runs against a real catalog
    model through `Kapelle.Product.LiveAgent`, reaches a verdict, and
    `RunVerdict.for_loop/1`'s `cost.tokens` carries a measured integer
    (`Kapelle.Product.AgentCalls` rows written by `StageShell.call_agent/4`,
    never a bare `0` standing in for "not instrumented"). The mix report's
    `format/1` names the live agent address and prints that same number,
    so what the owner reads is the one fact the verdict computed, not a
    second guess at it.

  The model address and iteration budget are owner calls (design doc
  Q-10, non-blocking, resolved per-run rather than hardcoded here) —
  override with `KAPELLE_LIVE_RUN_AGENT` (`model:<provider>@<model>`,
  default the catalog's cheapest entry) and `KAPELLE_LIVE_RUN_MAX_ITERATIONS`
  (default `1`) rather than editing this file.
  """

  use Kapelle.DataCase, async: false

  alias Kapelle.Product.{Loop, Loops, RunVerdict}
  alias Mix.Tasks.Kapelle.Product.Report

  @moduletag :live_product_run

  @golden_root "test/support/fixtures/golden"
  @default_agent "model:anthropic@claude-haiku-4-5"

  setup_all do
    case Application.get_env(:langchain, :anthropic_key) do
      key when is_binary(key) and key != "" ->
        :ok

      _absent ->
        flunk("""
        BEH-26: opt-in live run refused — ANTHROPIC_API_KEY is not set.

        `test/kapelle/product/live_run_smoke_test.exs` only runs at all
        under `mix test --include live_product_run`, and even then it
        refuses every example in this file right here, in `setup_all`,
        before any test body and before any network call. The missing
        variable is named above by name; its value is never printed
        because there is none to print. This is not a silent skip — the
        opt-in is not counted as passed — and it is not a network
        timeout either: nothing here waits on a connection.

        Set ANTHROPIC_API_KEY to a real Anthropic key and re-run:

            ANTHROPIC_API_KEY=sk-ant-... mix test --include live_product_run test/kapelle/product/live_run_smoke_test.exs
        """)
    end
  end

  test "BEH-27: a live end-to-end run reaches a verdict with a measured cost.tokens, and the report names the live agent" do
    agent = System.get_env("KAPELLE_LIVE_RUN_AGENT", @default_agent)

    max_iterations =
      "KAPELLE_LIVE_RUN_MAX_ITERATIONS"
      |> System.get_env("1")
      |> String.to_integer()

    loop_id = "LOOP-LIVE-#{System.unique_integer([:positive])}"

    {:ok, _loop_row} =
      Loop.start(idea_yaml(),
        loop_id: loop_id,
        proposal_id: "PP-LIVE-001",
        exchange_log_id: "XL-LIVE-001",
        max_iterations: max_iterations,
        agent: agent
      )

    assert %{discard: 0} = Oban.drain_queue(queue: :product, with_recursion: true)

    loop = Loops.get!(loop_id)

    assert loop.status in ["ready", "failed"],
           "loop did not reach a terminal status: #{loop.status}"

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)
    assert verdict.agent == agent

    assert is_integer(verdict.cost.tokens),
           "cost.tokens was not a measured number: #{inspect(verdict.cost.tokens)} " <>
             "(reason: #{inspect(verdict.cost.tokens_unavailable)}) — a retried attempt can " <>
             "leave usage :not_instrumented; per AC-22 this does not count as evidence and the " <>
             "run should be repeated"

    report = Report.format(verdict)

    assert report =~ "agent:   #{agent}"
    assert report =~ ~r/tokens:\s+#{Regex.escape(to_string(verdict.cost.tokens))}\n/
  end

  defp idea_yaml, do: File.read!(Path.join([@golden_root, "happy", "workspace", "idea.yaml"]))
end
