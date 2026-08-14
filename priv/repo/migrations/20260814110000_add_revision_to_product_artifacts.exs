defmodule Kapelle.Repo.Migrations.AddRevisionToProductArtifacts do
  use Ecto.Migration

  # Postgres can't alter a composite PK in place, so this is explicit:
  # drop the old (loop_id, kind, identity) constraint, add the column,
  # backfill it per kind (owner's revision-snapshot decision, 2026-08-14),
  # evict loop_state (it becomes a projection in a later task — the only
  # existing rows are test-seeded), then recreate the PK over the
  # four-part key.
  def up do
    execute "ALTER TABLE product_artifacts DROP CONSTRAINT product_artifacts_pkey"

    alter table(:product_artifacts) do
      add :revision, :integer, null: false, default: 0
    end

    execute """
    UPDATE product_artifacts
    SET revision = (doc->>'version')::integer
    WHERE kind = 'product_proposal'
    """

    execute """
    UPDATE product_artifacts
    SET revision = jsonb_array_length(doc->'entries')
    WHERE kind = 'exchange_log'
    """

    execute "DELETE FROM product_artifacts WHERE kind = 'loop_state'"

    execute """
    ALTER TABLE product_artifacts
    ADD CONSTRAINT product_artifacts_pkey PRIMARY KEY (loop_id, kind, identity, revision)
    """
  end

  def down do
    execute "ALTER TABLE product_artifacts DROP CONSTRAINT product_artifacts_pkey"

    execute """
    ALTER TABLE product_artifacts
    ADD CONSTRAINT product_artifacts_pkey PRIMARY KEY (loop_id, kind, identity)
    """

    alter table(:product_artifacts) do
      remove :revision
    end
  end
end
