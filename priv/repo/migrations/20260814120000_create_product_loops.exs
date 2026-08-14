defmodule Kapelle.Repo.Migrations.CreateProductLoops do
  use Ecto.Migration

  # product_loops is loop configuration plus a best-effort state
  # projection — not the authoritative artifact store (owner's
  # loop-state-leaves-the-store decision, 2026-08-14). latest_state is
  # deletable/reconstructible by definition and carries no revision of
  # its own; status/stop_reason are this codebase's own loop lifecycle.
  def change do
    create table(:product_loops, primary_key: false) do
      add :loop_id, :string, null: false, primary_key: true
      add :idea_identity, :string, null: false
      add :proposal_id, :string, null: false
      add :exchange_log_id, :string, null: false
      add :max_iterations, :integer, null: false
      add :agent, :string, null: false
      add :status, :string, null: false, default: "running"
      add :stop_reason, :string
      add :latest_state, :map

      timestamps(type: :utc_datetime)
    end
  end
end
