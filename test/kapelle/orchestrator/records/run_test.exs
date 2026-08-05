defmodule Kapelle.Orchestrator.Records.RunTest do
  use Kapelle.DataCase, async: true

  alias Kapelle.Orchestrator.Records.Run

  test "changeset/2 is valid with task_id and status" do
    changeset = Run.changeset(%Run{}, %{task_id: "task-1", status: "completed"})

    assert changeset.valid?
  end

  test "changeset/2 defaults status to \"pending\" when omitted" do
    changeset = Run.changeset(%Run{}, %{task_id: "task-1"})

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :status) == "pending"
  end

  test "changeset/2 requires task_id" do
    changeset = Run.changeset(%Run{}, %{})

    refute changeset.valid?
    assert %{task_id: ["can't be blank"]} = errors_on(changeset)
  end

  test "changeset/2 persists and reloads a run" do
    {:ok, run} =
      %Run{}
      |> Run.changeset(%{task_id: "task-1", status: "completed"})
      |> Repo.insert()

    assert %Run{task_id: "task-1", status: "completed"} = Repo.get!(Run, run.id)
  end

  test "changeset/2 defaults payload to an empty map when omitted" do
    changeset = Run.changeset(%Run{}, %{task_id: "task-1"})

    assert Ecto.Changeset.get_field(changeset, :payload) == %{}
  end

  test "changeset/2 casts and persists a caller-supplied payload" do
    {:ok, run} =
      %Run{}
      |> Run.changeset(%{task_id: "task-1", payload: %{"type" => "code_gen"}})
      |> Repo.insert()

    assert %Run{payload: %{"type" => "code_gen"}} = Repo.get!(Run, run.id)
  end
end
