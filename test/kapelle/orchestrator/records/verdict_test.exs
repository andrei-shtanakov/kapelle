defmodule Kapelle.Orchestrator.Records.VerdictTest do
  use Kapelle.DataCase, async: true

  alias Kapelle.Orchestrator.Records.Decision
  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Orchestrator.Records.RunTask
  alias Kapelle.Orchestrator.Records.Verdict

  setup do
    {:ok, run} = Repo.insert(Run.changeset(%Run{}, %{task_id: "task-1"}))

    {:ok, run_task} =
      Repo.insert(
        RunTask.changeset(%RunTask{}, %{run_id: run.id, task_id: "task-1", status: "pass"})
      )

    decision_attrs = %{
      id: Ecto.UUID.generate(),
      run_task_id: run_task.id,
      task_id: "task-1",
      target: %{"provider" => "openai", "model" => "gpt-5"},
      decided_at: DateTime.utc_now()
    }

    {:ok, decision} = Repo.insert(Decision.changeset(%Decision{}, decision_attrs))

    %{decision: decision}
  end

  test "changeset/2 is valid with decision_id, task_id, and total_score", %{decision: decision} do
    changeset =
      Verdict.changeset(%Verdict{}, %{
        decision_id: decision.id,
        task_id: "task-1",
        total_score: 1.0
      })

    assert changeset.valid?
  end

  test "changeset/2 requires decision_id, task_id, and total_score" do
    changeset = Verdict.changeset(%Verdict{}, %{})

    refute changeset.valid?

    assert %{
             decision_id: ["can't be blank"],
             task_id: ["can't be blank"],
             total_score: ["can't be blank"]
           } = errors_on(changeset)
  end

  test "changeset/2 defaults score_components to an empty map", %{decision: decision} do
    changeset =
      Verdict.changeset(%Verdict{}, %{
        decision_id: decision.id,
        task_id: "task-1",
        total_score: 1.0
      })

    assert Ecto.Changeset.get_field(changeset, :score_components) == %{}
  end

  test "changeset/2 persists and reloads a verdict linked to its decision", %{decision: decision} do
    {:ok, verdict} =
      %Verdict{}
      |> Verdict.changeset(%{
        decision_id: decision.id,
        task_id: "task-1",
        total_score: 0.75,
        score_components: %{"correctness" => 0.75}
      })
      |> Repo.insert()

    reloaded = Repo.get!(Verdict, verdict.id)
    assert reloaded.decision_id == decision.id
    assert reloaded.score_components == %{"correctness" => 0.75}
  end

  test "changeset/2 surfaces a unique_constraint on decision_id", %{decision: decision} do
    {:ok, _verdict} =
      Repo.insert(
        Verdict.changeset(%Verdict{}, %{
          decision_id: decision.id,
          task_id: "task-1",
          total_score: 1.0
        })
      )

    {:error, changeset} =
      %Verdict{}
      |> Verdict.changeset(%{decision_id: decision.id, task_id: "task-1", total_score: 0.5})
      |> Repo.insert()

    assert %{decision_id: ["has already been taken"]} = errors_on(changeset)
  end

  test "changeset/2 surfaces a foreign_key_constraint on a non-existent decision_id" do
    changeset =
      Verdict.changeset(%Verdict{}, %{
        decision_id: Ecto.UUID.generate(),
        task_id: "task-1",
        total_score: 1.0
      })

    {:error, changeset} = Repo.insert(changeset)

    assert %{decision_id: ["does not exist"]} = errors_on(changeset)
  end
end
