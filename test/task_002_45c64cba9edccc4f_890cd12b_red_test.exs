defmodule Kapelle.Product.Task002RedTest do
  @moduledoc """
  RED for TASK-002 (DT-02, BEH-15): the `StageShell` seam and the durable
  usage carrier do not exist yet. `Agent.resolve/1` already resolves a
  `model:` address to a **configured** module
  (`Application.get_env(:kapelle, :product_live_agent, ...)`), so a
  live-agent double can stand in for the real adapter without any network
  call — but the stage worker still unpacks `produce/3`'s return as the
  old two-element `{:ok, doc}` shape and nothing durably records the third
  element's `call_meta`. Driving one real research-stage attempt through
  the ordinary Oban worker on a double that reports measured usage must
  therefore still leave `RunVerdict.for_loop/1` reporting the token
  figure as unmeasured, which is exactly the gap BEH-15 closes.
  """

  use Kapelle.DataCase, async: false
  use Oban.Testing, repo: Kapelle.Repo

  alias Kapelle.Product.{Loop, RunVerdict}

  @golden_idea_path "test/support/fixtures/golden/happy/workspace/idea.yaml"
  @reported_tokens 42

  defmodule Double do
    @moduledoc "Inline adapter double reporting a measured, non-zero usage figure."

    @behaviour Kapelle.Product.Agent

    @impl true
    def produce(_role, _iteration, _context) do
      {:ok, %{}, %{model_id: "test@double", tokens: %{input: 10, output: 32, total: 42}}}
    end
  end

  test "BEH-15: usage the double reports becomes cost.tokens once the run completes" do
    previous_live_agent = Application.get_env(:kapelle, :product_live_agent)
    Application.put_env(:kapelle, :product_live_agent, Double)

    on_exit(fn ->
      case previous_live_agent do
        nil -> Application.delete_env(:kapelle, :product_live_agent)
        mod -> Application.put_env(:kapelle, :product_live_agent, mod)
      end
    end)

    loop_id = "LOOP-TASK-002-RED"

    {:ok, _row} =
      Loop.start(File.read!(@golden_idea_path),
        loop_id: loop_id,
        proposal_id: "PP-001",
        exchange_log_id: "XL-001",
        max_iterations: 1,
        agent: "model:test@double",
        now_iso: "2026-09-07T00:00:00Z"
      )

    Oban.drain_queue(queue: :product, with_recursion: true)

    assert {:ok, verdict} = RunVerdict.for_loop(loop_id)

    # BEH-15: the reported figure becomes cost.tokens, not an unmeasured gap.
    assert verdict.cost.tokens == @reported_tokens
    assert verdict.cost.tokens_unavailable == nil

    refute Enum.any?(
             verdict.harness_findings,
             &(&1.class in [:cost_not_instrumented, :cost_not_applicable])
           )

    assert verdict.harness == :pass
  end
end
