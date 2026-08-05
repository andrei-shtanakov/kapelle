defmodule Kapelle.Orchestrator.Workers.TerminalTest do
  use Kapelle.DataCase, async: true

  alias Kapelle.Orchestrator.Records.Run
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

    test "on the final attempt, overwrites an already-completed run's status unconditionally" do
      run = insert_run!("completed")
      job = %Oban.Job{attempt: 3, max_attempts: 3}

      assert {:discard, :boom} = Terminal.fail(run, job, :boom)
      assert Repo.get!(Run, run.id).status == "failed"
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
