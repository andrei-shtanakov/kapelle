defmodule Kapelle.Repo.Migrations.CreateProductAgentCalls do
  use Ecto.Migration

  # product_agent_calls is the durable usage carrier (design doc Q-03):
  # append-only, one row per attempted live-agent call — a resolved,
  # non-fixture `produce/3` invocation — regardless of how that call
  # ended. The three token columns are nullable: `nil` means the attempt
  # did not report usage, never a silent zero.
  def change do
    create table(:product_agent_calls) do
      add :loop_id, :string, null: false
      add :iteration, :integer, null: false
      add :role, :string, null: false
      add :model_id, :string
      add :tokens_input, :integer
      add :tokens_output, :integer
      add :tokens_total, :integer

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:product_agent_calls, [:loop_id])
  end
end
