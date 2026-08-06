defmodule Kapelle.Executor.ChainAdapterTest do
  use ExUnit.Case, async: true

  alias Kapelle.Executor.ChainAdapter
  alias Kapelle.Router.Decision

  defp decision(target \\ %{provider: "anthropic", model: "claude-sonnet-5"}) do
    Decision.new!(%{
      decision_id: Ecto.UUID.generate(),
      task_id: "task-1",
      target: target,
      decided_at: DateTime.utc_now()
    })
  end

  describe "execute/2" do
    test "returns {:error, :missing_prompt} when the task has no :prompt key" do
      assert {:error, :missing_prompt} = ChainAdapter.execute(%{id: "task-1"}, decision())
    end

    test "returns {:error, :missing_prompt} when :prompt is not a string" do
      task = %{id: "task-1", prompt: nil}

      assert {:error, :missing_prompt} = ChainAdapter.execute(task, decision())
    end

    test "propagates ModelFactory's unsupported provider error without any network call" do
      task = %{id: "task-1", prompt: "hello"}
      unsupported = decision(%{provider: "openai", model: "gpt-5"})

      assert {:error, {:unsupported_provider, "openai"}} =
               ChainAdapter.execute(task, unsupported)
    end

    test "propagates ModelFactory's unknown model error without any network call" do
      task = %{id: "task-1", prompt: "hello"}
      unknown = decision(%{provider: "nope", model: "nope"})

      assert {:error, {:unknown_model_id, "nope@nope"}} = ChainAdapter.execute(task, unknown)
    end
  end
end
