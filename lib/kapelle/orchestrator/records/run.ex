defmodule Kapelle.Orchestrator.Records.Run do
  @moduledoc """
  Ecto schema for the `runs` table.

  One row per `Kapelle.Orchestrator.Pipeline.run_sync/2` execution; owns
  the `run_tasks` produced while executing it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Kapelle.Orchestrator.Records.RunTask

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "runs" do
    field :task_id, :string
    field :status, :string, default: "completed"

    has_many :run_tasks, RunTask

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          task_id: String.t() | nil,
          status: String.t(),
          run_tasks: [RunTask.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @doc """
  Builds a changeset for `run`, casting `task_id`/`status` and requiring
  both, matching the `runs` table's NOT NULL columns.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(run, attrs) do
    run
    |> cast(attrs, [:task_id, :status])
    |> validate_required([:task_id, :status])
  end
end
