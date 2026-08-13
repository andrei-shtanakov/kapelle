defmodule Kapelle.Orchestrator.Workers.TerminalTest do
  use Kapelle.DataCase, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Multi
  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Orchestrator.RunEvents
  alias Kapelle.Orchestrator.Workers.Terminal

  defp insert_run!(status \\ "pending") do
    %Run{}
    |> Run.changeset(%{task_id: "task-1", status: status})
    |> Repo.insert!()
  end

  describe "fail/3" do
    test "on the final attempt, persists the run as failed and discards the job" do
      run = insert_run!()
      job = %Oban.Job{attempt: 3, max_attempts: 3}

      assert {:discard, :boom} = Terminal.fail(run, job, :boom)
      assert Repo.get!(Run, run.id).status == "failed"
    end

    test "on a genuine (non-terminal) run, the final attempt actually performs the transition, not a no-op" do
      run = insert_run!()
      job = %Oban.Job{attempt: 3, max_attempts: 3}

      assert {:discard, :boom} = Terminal.fail(run, job, :boom)

      # A follow-up transition finding 0 rows proves the row was already
      # terminal after `fail/3` ran — i.e. `fail/3`'s own update affected
      # exactly 1 row, not 0. If TASK-002 regressed `fail/3` into a no-op,
      # this follow-up would instead find the row still pending (count 1).
      assert {:ok, %{run: {0, nil}}} =
               Multi.new()
               |> Terminal.terminal_transition(:run, run.id, "failed")
               |> Repo.transaction()

      assert Repo.get!(Run, run.id).status == "failed"
    end

    test "on an attempt past max_attempts, still persists the run as failed and discards" do
      run = insert_run!()
      job = %Oban.Job{attempt: 4, max_attempts: 3}

      assert {:discard, :boom} = Terminal.fail(run, job, :boom)
      assert Repo.get!(Run, run.id).status == "failed"
    end

    test "on a non-final attempt, leaves the run's status untouched and returns {:error, _}" do
      run = insert_run!()
      job = %Oban.Job{attempt: 1, max_attempts: 3}

      assert {:error, :boom} = Terminal.fail(run, job, :boom)
      assert Repo.get!(Run, run.id).status == "pending"
    end

    test "on the final attempt, preserves an already-completed run's status" do
      run = insert_run!("completed")
      job = %Oban.Job{attempt: 3, max_attempts: 3}

      assert {:discard, :already_terminal} = Terminal.fail(run, job, :boom)
      assert Repo.get!(Run, run.id).status == "completed"
    end

    test "on the final attempt, preserves an already-failed run's status" do
      run = insert_run!("failed")
      job = %Oban.Job{attempt: 3, max_attempts: 3}

      assert {:discard, :already_terminal} = Terminal.fail(run, job, :boom)
      assert Repo.get!(Run, run.id).status == "failed"
    end

    test "a genuine transition to failed broadcasts a RunEvents update for the run" do
      run = insert_run!()
      job = %Oban.Job{attempt: 3, max_attempts: 3}
      :ok = RunEvents.subscribe(run.id)

      assert {:discard, :boom} = Terminal.fail(run, job, :boom)

      assert_receive {:run_updated, run_id}
      assert run_id == run.id
    end

    test "a no-op against an already-terminal run does not broadcast" do
      run = insert_run!("completed")
      job = %Oban.Job{attempt: 3, max_attempts: 3}
      :ok = RunEvents.subscribe(run.id)

      assert {:discard, :already_terminal} = Terminal.fail(run, job, :boom)

      refute_receive {:run_updated, _}, 50
    end
  end

  describe "terminal_transition/4" do
    test "transitions a non-terminal run to the given terminal status" do
      run = insert_run!("pending")

      assert {:ok, %{run: {1, nil}}} =
               Multi.new()
               |> Terminal.terminal_transition(:run, run.id, "failed")
               |> Repo.transaction()

      assert Repo.get!(Run, run.id).status == "failed"
    end

    test "is a no-op when the run is already completed" do
      run = insert_run!("completed")

      assert {:ok, %{run: {0, nil}}} =
               Multi.new()
               |> Terminal.terminal_transition(:run, run.id, "failed")
               |> Repo.transaction()

      assert Repo.get!(Run, run.id).status == "completed"
    end

    test "is a no-op when the run is already failed" do
      run = insert_run!("failed")

      assert {:ok, %{run: {0, nil}}} =
               Multi.new()
               |> Terminal.terminal_transition(:run, run.id, "completed")
               |> Repo.transaction()

      assert Repo.get!(Run, run.id).status == "failed"
    end

    test "repeated success is idempotent: a second completion transition against an already-completed run is a no-op" do
      run = insert_run!("pending")

      assert {:ok, %{run: {1, nil}}} =
               Multi.new()
               |> Terminal.terminal_transition(:run, run.id, "completed")
               |> Repo.transaction()

      completed = Repo.get!(Run, run.id)

      assert {:ok, %{run: {0, nil}}} =
               Multi.new()
               |> Terminal.terminal_transition(:run, run.id, "completed")
               |> Repo.transaction()

      assert Repo.get!(Run, run.id) == completed
    end

    test "updates updated_at alongside status" do
      run = insert_run!("pending")
      stale = ~N[2020-01-01 00:00:00]
      Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [updated_at: stale])

      assert {:ok, %{run: {1, nil}}} =
               Multi.new()
               |> Terminal.terminal_transition(:run, run.id, "completed")
               |> Repo.transaction()

      assert NaiveDateTime.compare(Repo.get!(Run, run.id).updated_at, stale) == :gt
    end

    test "raises on a status outside the terminal set" do
      run = insert_run!("pending")

      assert_raise FunctionClauseError, fn ->
        Multi.new() |> Terminal.terminal_transition(:run, run.id, "pending")
      end
    end

    test "composes with other steps in the same multi transaction" do
      run = insert_run!("pending")

      assert {:ok, %{run: {1, nil}, other: :marker}} =
               Multi.new()
               |> Terminal.terminal_transition(:run, run.id, "completed")
               |> Multi.run(:other, fn _repo, _changes -> {:ok, :marker} end)
               |> Repo.transaction()
    end
  end

  describe "concurrent finalizers" do
    test "a failure and a success racing on the same run: exactly one transition wins, and the run ends in exactly one terminal status" do
      run = insert_run!("pending")
      job = %Oban.Job{attempt: 3, max_attempts: 3}
      owner = self()

      [fail_result, success_result] =
        [
          fn ->
            Sandbox.allow(Repo, owner, self())
            Terminal.fail(run, job, :boom)
          end,
          fn ->
            Sandbox.allow(Repo, owner, self())

            Multi.new()
            |> Terminal.terminal_transition(:run, run.id, "completed")
            |> Repo.transaction()
          end
        ]
        |> Enum.map(&Task.async/1)
        |> Task.await_many(5_000)

      # `fail_count`/`success_count` are the row counts each finalizer's
      # conditional UPDATE affected — the DB-state proof that exactly one
      # of the two writes committed, rather than relying on which
      # `Task.async` happened to run first.
      fail_count =
        case fail_result do
          {:discard, :boom} -> 1
          {:discard, :already_terminal} -> 0
        end

      assert {:ok, %{run: {success_count, nil}}} = success_result

      assert fail_count + success_count == 1
      assert Repo.get!(Run, run.id).status in ["completed", "failed"]
    end
  end

  describe "unique_violation?/2" do
    test "true when the changeset has a unique constraint error on the given field" do
      changeset =
        Ecto.Changeset.add_error(%Ecto.Changeset{}, :decision_id, "has already been taken",
          constraint: :unique
        )

      assert Terminal.unique_violation?(changeset, :decision_id)
    end

    test "false when the error on the field isn't a unique constraint" do
      changeset = Ecto.Changeset.add_error(%Ecto.Changeset{}, :decision_id, "can't be blank")

      refute Terminal.unique_violation?(changeset, :decision_id)
    end

    test "false when the unique constraint error is on a different field" do
      changeset =
        Ecto.Changeset.add_error(%Ecto.Changeset{}, :run_id, "has already been taken",
          constraint: :unique
        )

      refute Terminal.unique_violation?(changeset, :decision_id)
    end

    test "false when the changeset has no errors" do
      refute Terminal.unique_violation?(%Ecto.Changeset{}, :decision_id)
    end
  end
end
