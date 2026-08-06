defmodule Kapelle.Executor.ChainAdapterSmokeTest do
  @moduledoc """
  Opt-in provider smoke test (REQ-006): proves `ChainAdapter` carries a real
  Anthropic completion through `Pipeline.run_sync/2` to a `Verdict`.

  Excluded by default (`test/test_helper.exs`). Run with:

      ANTHROPIC_API_KEY=sk-... mix test --include provider_smoke
  """

  use Kapelle.DataCase, async: true

  @moduletag :provider_smoke

  alias Kapelle.Evaluator.Verdict
  alias Kapelle.Executor.ChainAdapter
  alias Kapelle.Orchestrator.Pipeline

  setup do
    case System.get_env("ANTHROPIC_API_KEY") do
      key when is_binary(key) and key != "" -> :ok
      _missing -> raise "ANTHROPIC_API_KEY must be set to run the :provider_smoke suite"
    end
  end

  test "run_sync/2 with ChainAdapter carries a real completion through to a Verdict" do
    task = %{
      id: "provider-smoke-1",
      type: :general,
      prompt: "Reply with exactly one word: ok"
    }

    assert {:ok, %Verdict{} = verdict} = Pipeline.run_sync(task, adapter: ChainAdapter)

    assert verdict.task_id == "provider-smoke-1"
  end
end
