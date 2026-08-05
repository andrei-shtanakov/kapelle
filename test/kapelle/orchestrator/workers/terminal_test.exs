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
  end
end
