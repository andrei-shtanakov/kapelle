defmodule Kapelle.Test.RoutePolicy do
  @moduledoc """
  `Kapelle.Router.Policy` test double matching the atom-keyed task shape
  `RouteWorker` builds via `Persistence.atomize_task/1` (the same shape
  `Pipeline.run_sync/2` passes directly). Returns `{:error, :unroutable}`
  for `%{id: "unroutable"}` so routing-failure paths are reachable too.
  """

  @behaviour Kapelle.Router.Policy

  alias Kapelle.Router.Decision

  @impl true
  def route(%{id: "unroutable"}, _opts), do: {:error, :unroutable}

  def route(%{id: task_id}, _opts) do
    {:ok,
     Decision.new!(%{
       decision_id: Ecto.UUID.generate(),
       task_id: task_id,
       target: %{provider: "anthropic", model: "claude-sonnet-5"},
       decided_at: DateTime.utc_now()
     })}
  end
end
