defmodule Kapelle.Orchestrator.Records.RunTaskTest do
  use Kapelle.DataCase, async: true

  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Orchestrator.Records.RunTask

  setup do
    {:ok, run} = Repo.insert(Run.changeset(%Run{}, %{task_id: "task-1"}))
    %{run: run}
  end

  test "changeset/2 is valid with run_id, task_id, and status", %{run: run} do
    changeset =
      RunTask.changeset(%RunTask{}, %{run_id: run.id, task_id: "task-1", status: "pass"})

    assert changeset.valid?
  end

  test "changeset/2 requires run_id, task_id, and status" do
    changeset = RunTask.changeset(%RunTask{}, %{})

    refute changeset.valid?

    assert %{run_id: ["can't be blank"], task_id: ["can't be blank"], status: ["can't be blank"]} =
             errors_on(changeset)
  end

  test "changeset/2 defaults artifacts to an empty list", %{run: run} do
    changeset =
      RunTask.changeset(%RunTask{}, %{run_id: run.id, task_id: "task-1", status: "pass"})

    assert Ecto.Changeset.get_field(changeset, :artifacts) == []
  end

  test "changeset/2 casts output, duration_ms, and artifacts", %{run: run} do
    attrs = %{
      run_id: run.id,
      task_id: "task-1",
      status: "pass",
      output: %{"text" => "ok"},
      duration_ms: 42,
      artifacts: [%{"kind" => "log"}]
    }

    changeset = RunTask.changeset(%RunTask{}, attrs)

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :output) == %{"text" => "ok"}
    assert Ecto.Changeset.get_field(changeset, :duration_ms) == 42
    assert Ecto.Changeset.get_field(changeset, :artifacts) == [%{"kind" => "log"}]
  end

  test "changeset/2 persists and reloads a run_task linked to its run", %{run: run} do
    {:ok, run_task} =
      %RunTask{}
      |> RunTask.changeset(%{run_id: run.id, task_id: "task-1", status: "pass"})
      |> Repo.insert()

    assert %RunTask{run_id: run_id} = Repo.get!(RunTask, run_task.id)
    assert run_id == run.id
  end

  test "changeset/2 persists and reloads artifacts as a list of maps" do
    {:ok, run} = Repo.insert(Run.changeset(%Run{}, %{task_id: "task-1"}))

    {:ok, run_task} =
      %RunTask{}
      |> RunTask.changeset(%{
        run_id: run.id,
        task_id: "task-1",
        status: "pass",
        artifacts: [%{"kind" => "log", "path" => "/tmp/out.log"}]
      })
      |> Repo.insert()

    reloaded = Repo.get!(RunTask, run_task.id)
    assert reloaded.artifacts == [%{"kind" => "log", "path" => "/tmp/out.log"}]
  end

  test "changeset/2 surfaces a foreign_key_constraint on a non-existent run_id" do
    changeset =
      RunTask.changeset(%RunTask{}, %{
        run_id: Ecto.UUID.generate(),
        task_id: "task-1",
        status: "pass"
      })

    {:error, changeset} = Repo.insert(changeset)

    assert %{run_id: ["does not exist"]} = errors_on(changeset)
  end
end
