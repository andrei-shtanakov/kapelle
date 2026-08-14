defmodule Kapelle.Repo.Migrations.AddTargetRejectedToRunTasks do
  use Ecto.Migration

  def change do
    alter table(:run_tasks) do
      add :target, :string
      add :rejected, {:array, :map}, null: false, default: []
    end
  end
end
