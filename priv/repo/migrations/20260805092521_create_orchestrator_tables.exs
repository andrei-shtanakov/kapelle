defmodule Kapelle.Repo.Migrations.CreateOrchestratorTables do
  use Ecto.Migration

  def change do
    create table(:runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task_id, :string, null: false
      add :status, :string, null: false, default: "completed"

      timestamps()
    end

    create table(:run_tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false

      add :task_id, :string, null: false
      add :status, :string, null: false
      add :output, :map
      add :duration_ms, :integer
      add :artifacts, {:array, :map}, default: []

      timestamps()
    end

    create index(:run_tasks, [:run_id])

    create table(:decisions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :run_task_id, references(:run_tasks, type: :binary_id, on_delete: :delete_all),
        null: false

      add :task_id, :string, null: false
      add :target, :map, null: false
      add :features, :map, default: %{}
      add :decided_at, :utc_datetime_usec, null: false

      timestamps()
    end

    create unique_index(:decisions, [:run_task_id])

    create table(:verdicts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :decision_id, references(:decisions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :task_id, :string, null: false
      add :total_score, :float, null: false
      add :score_components, :map, default: %{}

      timestamps()
    end

    create unique_index(:verdicts, [:decision_id])
  end
end
