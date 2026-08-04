defmodule Kapelle.Executor.FakeAdapterTest do
  use ExUnit.Case, async: true

  alias Kapelle.Executor.FakeAdapter
  alias Kapelle.Executor.Result
  alias Kapelle.Router.Decision

  defp decision do
    Decision.new!(%{
      decision_id: "decision-1",
      task_id: "task-1",
      target: %{provider: "anthropic", model: "claude-sonnet-5"},
      decided_at: DateTime.utc_now()
    })
  end

  test "execute/2 returns a canned :pass Result by default" do
    task = %{id: "task-1", type: :code_gen}

    assert {:ok, %Result{} = result} = FakeAdapter.execute(task, decision())
    assert result.task_id == "task-1"
    assert result.status == :pass
  end

  test "execute/2 returns a Result overridden by task[:fake_result]" do
    task = %{id: "task-2", type: :code_gen, fake_result: %{status: :fail, output: "boom"}}

    assert {:ok, %Result{} = result} = FakeAdapter.execute(task, decision())
    assert result.status == :fail
    assert result.output == "boom"
  end

  test "execute/2 returns a configured {:error, reason} without raising" do
    task = %{id: "task-4", type: :code_gen, fake_result: {:error, :boom}}

    assert {:error, :boom} = FakeAdapter.execute(task, decision())
  end

  test "execute/2 makes no network calls (canned result only)" do
    task = %{id: "task-3", type: :general, fake_result: %{status: :error}}

    assert {:ok, %Result{status: :error}} = FakeAdapter.execute(task, decision())
  end

  test "execute/2 treats an explicit nil fake_result as no overrides" do
    task = %{id: "task-4", type: :general, fake_result: nil}

    assert {:ok, %Result{task_id: "task-4", status: :pass}} =
             FakeAdapter.execute(task, decision())
  end

  test "execute/2 returns a clear error for a non-map non-error fake_result" do
    for bad <- ["oops", 42, [status: :pass]] do
      task = %{id: "task-5", type: :general, fake_result: bad}

      assert {:error, {:invalid_fake_result, ^bad}} = FakeAdapter.execute(task, decision())
    end
  end

  test "FakeAdapter implements the Kapelle.Executor.Adapter behaviour" do
    assert Kapelle.Executor.Adapter in (FakeAdapter.module_info(:attributes)
                                        |> Keyword.get_values(:behaviour)
                                        |> List.flatten())
  end
end
