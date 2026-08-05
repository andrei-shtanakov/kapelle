defmodule Kapelle.Test.StubPolicy do
  @moduledoc """
  `Kapelle.Router.Policy` test double returning a fixed decision_id, so tests
  can assert the decision→verdict link end-to-end. The id is a valid UUID
  since `decisions.id` is a `binary_id` column.
  """

  @behaviour Kapelle.Router.Policy

  alias Kapelle.Router.Decision

  @impl true
  def route(%{id: task_id}, _opts) do
    {:ok,
     Decision.new!(%{
       decision_id: "11111111-1111-1111-1111-111111111111",
       task_id: task_id,
       target: %{provider: "anthropic", model: "claude-sonnet-5"},
       decided_at: DateTime.utc_now()
     })}
  end
end
