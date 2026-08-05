defmodule Kapelle.Orchestrator.Records.RunTask do
  @moduledoc """
  Ecto schema for the `run_tasks` table.

  One row per `Kapelle.Executor.Result` produced while executing a step
  of a `Kapelle.Orchestrator.Records.Run`; owns the `decision` routed for
  that step.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Kapelle.Orchestrator.Records.Decision
  alias Kapelle.Orchestrator.Records.Run

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "run_tasks" do
    field :task_id, :string
    field :status, :string
    field :output, :map
    field :duration_ms, :integer
    field :artifacts, {:array, :map}, default: []

    belongs_to :run, Run
    has_one :decision, Decision

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          task_id: String.t() | nil,
          status: String.t() | nil,
          output: map() | nil,
          duration_ms: non_neg_integer() | nil,
          artifacts: [map()],
          run_id: Ecto.UUID.t() | nil,
          run: Run.t() | Ecto.Association.NotLoaded.t(),
          decision: Decision.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Builds a changeset for `run_task`, casting all `run_tasks` fields and
  requiring `run_id`, `task_id`, and `status`, matching the table's NOT
  NULL columns.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(run_task, attrs) do
    run_task
    |> cast(attrs, [:run_id, :task_id, :status, :output, :duration_ms, :artifacts])
    |> validate_required([:run_id, :task_id, :status])
    |> foreign_key_constraint(:run_id)
  end
end
