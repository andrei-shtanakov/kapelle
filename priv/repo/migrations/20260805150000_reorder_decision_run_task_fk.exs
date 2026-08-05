defmodule Kapelle.Repo.Migrations.ReorderDecisionRunTaskFk do
  @moduledoc """
  Reorders the decision/run_task/run relationship so `decisions` points
  directly at `runs` (`decisions.run_id`) and `run_tasks` points at
  `decisions` (`run_tasks.decision_id`), replacing the original
  `decisions.run_task_id` indirection. Also adds `runs.overrides` for
  TASK-006's id-only job args (REQ-007).

  Deliberately rewritten in place rather than superseded by a new
  migration: as of this change it has not run against any deployed
  database (branch-local, unreleased), so there is no live data whose
  history this rewrite could disturb. This is a one-time exception —
  once released, any further correction to this relationship must ship
  as a new migration, not another in-place edit.
  """
  use Ecto.Migration
  import Ecto.Query, only: [from: 2]

  def up do
    alter table(:runs) do
      add :payload, :map, null: false, default: %{}
      add :overrides, :map, null: false, default: %{}
    end

    alter table(:decisions) do
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all)
    end

    alter table(:run_tasks) do
      add :decision_id, references(:decisions, type: :binary_id, on_delete: :delete_all)
    end

    flush()

    # Backfill from the existing decisions.run_task_id / run_tasks.run_id link.
    execute("""
    UPDATE decisions SET run_id = run_tasks.run_id
    FROM run_tasks
    WHERE run_tasks.id = decisions.run_task_id
    """)

    execute("""
    UPDATE run_tasks SET decision_id = decisions.id
    FROM decisions
    WHERE decisions.run_task_id = run_tasks.id
    """)

    flush()

    # Verify before tightening constraints — abort loudly rather than
    # silently shipping NULLs into a NOT NULL column.
    unbackfilled_decisions =
      repo().one(from(d in "decisions", where: is_nil(d.run_id), select: count(d.id)))

    unbackfilled_run_tasks =
      repo().one(from(rt in "run_tasks", where: is_nil(rt.decision_id), select: count(rt.id)))

    if unbackfilled_decisions > 0 or unbackfilled_run_tasks > 0 do
      raise "reorder_decision_run_task_fk: #{unbackfilled_decisions} decisions and " <>
              "#{unbackfilled_run_tasks} run_tasks have no backfilled FK; refusing to " <>
              "set NOT NULL against incomplete data"
    end

    alter table(:decisions) do
      modify :run_id, :binary_id, null: false
    end

    alter table(:run_tasks) do
      modify :decision_id, :binary_id, null: false
    end

    create unique_index(:decisions, [:run_id])
    create unique_index(:run_tasks, [:decision_id])

    drop unique_index(:decisions, [:run_task_id])

    alter table(:decisions) do
      remove :run_task_id, references(:run_tasks, type: :binary_id, on_delete: :delete_all)
    end
  end

  def down do
    alter table(:decisions) do
      add :run_task_id, references(:run_tasks, type: :binary_id, on_delete: :delete_all)
    end

    flush()

    # The forward migration's unique indexes make this relationship
    # provably 1:1 in both directions, so this reversal is a real,
    # lossless backfill — not a documented no-op.
    execute("""
    UPDATE decisions SET run_task_id = run_tasks.id
    FROM run_tasks
    WHERE run_tasks.decision_id = decisions.id
    """)

    flush()

    alter table(:decisions) do
      modify :run_task_id, :binary_id, null: false
    end

    create unique_index(:decisions, [:run_task_id])

    drop unique_index(:run_tasks, [:decision_id])
    drop unique_index(:decisions, [:run_id])

    alter table(:run_tasks) do
      remove :decision_id
    end

    alter table(:decisions) do
      remove :run_id
    end

    alter table(:runs) do
      remove :overrides
      remove :payload
    end
  end
end
