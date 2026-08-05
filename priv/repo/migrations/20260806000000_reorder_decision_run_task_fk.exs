defmodule Kapelle.Repo.Migrations.ReorderDecisionRunTaskFk do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :payload, :map, null: false, default: %{}
    end

    alter table(:decisions) do
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false
    end

    alter table(:run_tasks) do
      add :decision_id, references(:decisions, type: :binary_id, on_delete: :delete_all),
        null: false
    end

    create unique_index(:decisions, [:run_id])
    create unique_index(:run_tasks, [:decision_id])

    drop unique_index(:decisions, [:run_task_id])

    alter table(:decisions) do
      remove :run_task_id, references(:run_tasks, type: :binary_id, on_delete: :delete_all),
        null: false
    end
  end
end
