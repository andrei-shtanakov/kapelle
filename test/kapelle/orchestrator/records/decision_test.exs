defmodule Kapelle.Orchestrator.Records.DecisionTest do
  use Kapelle.DataCase, async: true

  alias Kapelle.Orchestrator.Records.Decision
  alias Kapelle.Orchestrator.Records.Run

  setup do
    {:ok, run} = Repo.insert(Run.changeset(%Run{}, %{task_id: "task-1"}))

    %{run: run}
  end

  defp valid_attrs(run) do
    %{
      id: Ecto.UUID.generate(),
      run_id: run.id,
      task_id: "task-1",
      target: %{"provider" => "openai", "model" => "gpt-5"},
      decided_at: DateTime.utc_now()
    }
  end

  test "changeset/2 is valid with id, run_id, task_id, target, and decided_at", %{
    run: run
  } do
    changeset = Decision.changeset(%Decision{}, valid_attrs(run))

    assert changeset.valid?
  end

  test "changeset/2 requires id, run_id, task_id, target, and decided_at" do
    changeset = Decision.changeset(%Decision{}, %{})

    refute changeset.valid?

    assert %{
             id: ["can't be blank"],
             run_id: ["can't be blank"],
             task_id: ["can't be blank"],
             target: ["can't be blank"],
             decided_at: ["can't be blank"]
           } = errors_on(changeset)
  end

  test "changeset/2 defaults features to an empty map", %{run: run} do
    changeset = Decision.changeset(%Decision{}, valid_attrs(run))

    assert Ecto.Changeset.get_field(changeset, :features) == %{}
  end

  test "changeset/2 persists a decision using the caller-supplied id", %{run: run} do
    attrs = valid_attrs(run)

    {:ok, decision} =
      %Decision{}
      |> Decision.changeset(attrs)
      |> Repo.insert()

    assert decision.id == attrs.id
    assert %Decision{run_id: run_id} = Repo.get!(Decision, attrs.id)
    assert run_id == run.id
  end

  test "changeset/2 surfaces a unique_constraint on run_id", %{run: run} do
    attrs = valid_attrs(run)
    {:ok, _decision} = Repo.insert(Decision.changeset(%Decision{}, attrs))

    other_attrs = %{attrs | id: Ecto.UUID.generate()}

    {:error, changeset} =
      %Decision{}
      |> Decision.changeset(other_attrs)
      |> Repo.insert()

    assert %{run_id: ["has already been taken"]} = errors_on(changeset)
  end

  test "changeset/2 surfaces a unique_constraint on a reused id", %{run: run} do
    attrs = valid_attrs(run)
    {:ok, _decision} = Repo.insert(Decision.changeset(%Decision{}, attrs))

    {:ok, other_run} = Repo.insert(Run.changeset(%Run{}, %{task_id: "task-1"}))

    other_attrs = %{attrs | run_id: other_run.id}

    {:error, changeset} =
      %Decision{}
      |> Decision.changeset(other_attrs)
      |> Repo.insert()

    assert %{id: ["has already been taken"]} = errors_on(changeset)
  end

  test "changeset/2 surfaces a foreign_key_constraint on a non-existent run_id" do
    attrs = %{
      id: Ecto.UUID.generate(),
      run_id: Ecto.UUID.generate(),
      task_id: "task-1",
      target: %{"provider" => "openai", "model" => "gpt-5"},
      decided_at: DateTime.utc_now()
    }

    {:error, changeset} =
      %Decision{}
      |> Decision.changeset(attrs)
      |> Repo.insert()

    assert %{run_id: ["does not exist"]} = errors_on(changeset)
  end
end
