defmodule Kapelle.Orchestrator.Records.Verdict do
  @moduledoc """
  Ecto schema for the `verdicts` table.

  One row per `Kapelle.Evaluator.Verdict` produced while evaluating a
  `decision`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Kapelle.Orchestrator.Records.Decision

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "verdicts" do
    field :task_id, :string
    field :total_score, :float
    field :score_components, :map, default: %{}

    belongs_to :decision, Decision

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          task_id: String.t() | nil,
          total_score: float() | nil,
          score_components: map(),
          decision_id: Ecto.UUID.t() | nil,
          decision: Decision.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Builds a changeset for `verdict`, casting the `verdicts` fields and
  requiring `decision_id`, `task_id`, and `total_score`, matching the
  table's NOT NULL columns.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(verdict, attrs) do
    verdict
    |> cast(attrs, [:decision_id, :task_id, :total_score, :score_components])
    |> validate_required([:decision_id, :task_id, :total_score])
    |> unique_constraint(:decision_id)
    |> foreign_key_constraint(:decision_id)
  end
end
