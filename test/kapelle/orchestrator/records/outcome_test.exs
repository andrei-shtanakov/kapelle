defmodule Kapelle.Orchestrator.Records.OutcomeTest do
  use Kapelle.DataCase, async: true

  alias Kapelle.Orchestrator.Records.Decision
  alias Kapelle.Orchestrator.Records.Outcome
  alias Kapelle.Orchestrator.Records.Run

  setup do
    {:ok, run} = Repo.insert(Run.changeset(%Run{}, %{task_id: "task-1"}))

    decision_attrs = %{
      id: Ecto.UUID.generate(),
      run_id: run.id,
      task_id: "task-1",
      target: %{"provider" => "openai", "model" => "gpt-5"},
      decided_at: DateTime.utc_now()
    }

    {:ok, decision} = Repo.insert(Decision.changeset(%Decision{}, decision_attrs))

    %{decision: decision}
  end

  test "changeset/2 is valid with decision_id, task_id, and type", %{decision: decision} do
    changeset =
      Outcome.changeset(%Outcome{}, %{
        decision_id: decision.id,
        task_id: "task-1",
        type: "success"
      })

    assert changeset.valid?
  end

  test "changeset/2 requires decision_id, task_id, and type" do
    changeset = Outcome.changeset(%Outcome{}, %{})

    refute changeset.valid?

    assert %{
             decision_id: ["can't be blank"],
             task_id: ["can't be blank"],
             type: ["can't be blank"]
           } = errors_on(changeset)
  end

  test "changeset/2 rejects a type outside success/failure", %{decision: decision} do
    changeset =
      Outcome.changeset(%Outcome{}, %{
        decision_id: decision.id,
        task_id: "task-1",
        type: "maybe"
      })

    refute changeset.valid?
    assert %{type: ["is invalid"]} = errors_on(changeset)
  end

  test "changeset/2 persists and reloads an outcome linked to its decision", %{
    decision: decision
  } do
    {:ok, outcome} =
      %Outcome{}
      |> Outcome.changeset(%{decision_id: decision.id, task_id: "task-1", type: "success"})
      |> Repo.insert()

    reloaded = Repo.get!(Outcome, outcome.id)
    assert reloaded.decision_id == decision.id
    assert reloaded.type == "success"
  end

  test "changeset/2 surfaces a unique_constraint on decision_id", %{decision: decision} do
    {:ok, _outcome} =
      Repo.insert(
        Outcome.changeset(%Outcome{}, %{
          decision_id: decision.id,
          task_id: "task-1",
          type: "success"
        })
      )

    {:error, changeset} =
      %Outcome{}
      |> Outcome.changeset(%{decision_id: decision.id, task_id: "task-1", type: "failure"})
      |> Repo.insert()

    assert %{decision_id: ["has already been taken"]} = errors_on(changeset)
  end

  test "changeset/2 surfaces a foreign_key_constraint on a non-existent decision_id" do
    changeset =
      Outcome.changeset(%Outcome{}, %{
        decision_id: Ecto.UUID.generate(),
        task_id: "task-1",
        type: "success"
      })

    {:error, changeset} = Repo.insert(changeset)

    assert %{decision_id: ["does not exist"]} = errors_on(changeset)
  end
end
