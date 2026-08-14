defmodule Kapelle.Repo.Migrations.CreateProductArtifacts do
  use Ecto.Migration

  def change do
    create table(:product_artifacts, primary_key: false) do
      add :loop_id, :string, null: false, primary_key: true
      add :kind, :string, null: false, primary_key: true
      add :identity, :string, null: false, primary_key: true
      add :canonical_hash, :string, null: false
      add :doc, :map, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end
  end
end
