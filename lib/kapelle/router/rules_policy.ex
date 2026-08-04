defmodule Kapelle.Router.RulesPolicy do
  @moduledoc """
  `Kapelle.Router.Policy` implementation routing tasks via explicit,
  pattern-matched rules.

  The target for a given task shape is fixed: the same task always routes to
  the same provider/model. Each call still gets a fresh `decision_id`
  (`Ecto.UUID.generate/0`), so every decision remains individually traceable.
  """

  @behaviour Kapelle.Router.Policy

  alias Kapelle.Router.Decision

  @impl true
  def route(%{id: task_id, type: :code_gen}, _opts) do
    decide(task_id, %{provider: "anthropic", model: "claude-sonnet-5"})
  end

  def route(%{id: task_id, type: :summarize}, _opts) do
    decide(task_id, %{provider: "anthropic", model: "claude-haiku-4-5"})
  end

  def route(%{id: task_id, type: :general}, _opts) do
    decide(task_id, %{provider: "anthropic", model: "claude-sonnet-5"})
  end

  def route(task, _opts) do
    {:error, {:unknown_task_shape, task}}
  end

  defp decide(task_id, target) do
    {:ok,
     Decision.new!(%{
       decision_id: Ecto.UUID.generate(),
       task_id: task_id,
       target: target,
       decided_at: DateTime.utc_now()
     })}
  end
end
