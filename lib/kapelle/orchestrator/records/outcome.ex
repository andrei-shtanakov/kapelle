defmodule Kapelle.Orchestrator.Records.Outcome do
  @moduledoc """
  Ecto schema for the `outcomes` table.

  One row per `Kapelle.Router.Outcome` derived from a decision's terminal
  `Verdict` — the typed success/failure signal fed back to the router
  (REQ-102).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Kapelle.Orchestrator.Records.Decision

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types ~w(success failure)

  schema "outcomes" do
    field :task_id, :string
    field :type, :string

    belongs_to :decision, Decision

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          task_id: String.t() | nil,
          type: String.t() | nil,
          decision_id: Ecto.UUID.t() | nil,
          decision: Decision.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Builds a changeset for `outcome`, casting the `outcomes` fields and
  requiring `decision_id`, `task_id`, and `type`, matching the table's
  NOT NULL columns. `type` must be `"success"` or `"failure"`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(outcome, attrs) do
    outcome
    |> cast(attrs, [:decision_id, :task_id, :type])
    |> validate_required([:decision_id, :task_id, :type])
    |> validate_inclusion(:type, @types)
    |> unique_constraint(:decision_id)
    |> foreign_key_constraint(:decision_id)
  end
end
