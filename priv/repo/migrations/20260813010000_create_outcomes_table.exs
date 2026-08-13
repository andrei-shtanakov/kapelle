defmodule Kapelle.Repo.Migrations.CreateOutcomesTable do
  use Ecto.Migration

  def change do
    create table(:outcomes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :decision_id, references(:decisions, type: :binary_id, on_delete: :delete_all),
        null: false

      add :task_id, :string, null: false
      add :type, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:outcomes, [:decision_id])
  end
end
