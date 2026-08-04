defmodule Kapelle.Test.StubPolicy do
  @moduledoc """
  `Kapelle.Router.Policy` test double returning a fixed decision_id, so tests
  can assert the decision→verdict link end-to-end.
  """

  @behaviour Kapelle.Router.Policy

  alias Kapelle.Router.Decision

  @impl true
  def route(%{id: task_id}, _opts) do
    {:ok,
     Decision.new!(%{
       decision_id: "stub-decision-id",
       task_id: task_id,
       target: %{provider: "anthropic", model: "claude-sonnet-5"},
       decided_at: DateTime.utc_now()
     })}
  end
end
