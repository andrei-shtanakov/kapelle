defmodule Kapelle.Orchestrator.Persistence do
  @moduledoc """
  Per-stage write + reload API for the orchestrator pipeline: one write
  function and one loader per stage (`run`, `decision`, `run_task`,
  `verdict`), backed by plain `Repo` calls rather than a single
  `Ecto.Multi`. `Pipeline.run_sync/2` and the (future) Oban workers call
  these in sequence, so both code paths share identical persistence
  semantics.

  Loaders reconstruct the plain contract structs the behaviours expect
  (`Kapelle.Router.Decision`, `Kapelle.Executor.Result`), not raw Ecto
  schemas, via `to_contract/1`.
  """

  import Ecto.Query, only: [from: 2]

  alias Kapelle.Evaluator.Verdict
  alias Kapelle.Executor.Result
  alias Kapelle.Orchestrator.Records.Decision, as: DecisionRecord
  alias Kapelle.Orchestrator.Records.Outcome, as: OutcomeRecord
  alias Kapelle.Orchestrator.Records.Run
  alias Kapelle.Orchestrator.Records.RunTask
  alias Kapelle.Orchestrator.Records.Verdict, as: VerdictRecord
  alias Kapelle.Repo
  alias Kapelle.Router.Decision
  alias Kapelle.Router.Outcome

  @doc """
  Builds insert attrs for `Records.Run` from the submitted `task` map.
  """
  @spec run_attrs(map()) :: map()
  def run_attrs(task) when is_map(task) do
    %{task_id: Map.fetch!(task, :id), status: "completed"}
  end

  @doc """
  Inserts a `Records.Run` row for the submitted `task` map.
  """
  @spec create_run(map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def create_run(task) when is_map(task) do
    %Run{}
    |> Run.changeset(run_attrs(task))
    |> Repo.insert()
  end

  @doc """
  Reloads the `Records.Run` row for `run_id`.

  Raises `Ecto.NoResultsError` if no row matches `run_id`.
  """
  @spec get_run!(Ecto.UUID.t()) :: Run.t()
  def get_run!(run_id) do
    Repo.get!(Run, run_id)
  end

  @doc """
  Lists all `Records.Run` rows, most recently inserted first, for the runs
  index page (REQ-103).
  """
  @spec list_runs() :: [Run.t()]
  def list_runs do
    Repo.all(from r in Run, order_by: [desc: r.inserted_at])
  end

  @doc """
  Reloads the `Records.Run` row for `run_id` with its `decision` (and the
  decision's `run_task`/`verdict`) preloaded, for the run detail page
  (REQ-103). `decision` is `nil` until `RouteWorker` routes the run; its
  `run_task`/`verdict` are `nil` until `ExecuteWorker`/`EvaluateWorker`
  reach it.

  Raises `Ecto.NoResultsError` if no row matches `run_id`.
  """
  @spec get_run_with_details!(Ecto.UUID.t()) :: Run.t()
  def get_run_with_details!(run_id) do
    Run
    |> Repo.get!(run_id)
    |> Repo.preload(decision: [:run_task, :verdict])
  end

  @doc """
  Builds a `Records.Run` changeset for a pending run, storing the full
  `task` map as `payload` so `RouteWorker` can later reload the task it was
  never given directly from Postgres.

  Additive alongside `run_attrs/1`/`create_run/1`, which `run_sync/2` still
  uses unmodified.
  """
  @spec pending_run_changeset(map()) :: Ecto.Changeset.t()
  def pending_run_changeset(task) when is_map(task) do
    Run.changeset(%Run{}, %{task_id: Map.fetch!(task, :id), status: "pending", payload: task})
  end

  @doc """
  Builds a `Records.Run` changeset for a pending run, same as
  `pending_run_changeset/1`, but also setting `overrides` — the
  `policy`/`adapter`/`judge` selection persisted on the run row so
  workers resolve it from `Persistence.get_run!/1` instead of job args.
  """
  @spec pending_run_changeset(map(), map()) :: Ecto.Changeset.t()
  def pending_run_changeset(task, overrides) when is_map(task) and is_map(overrides) do
    Run.changeset(%Run{}, %{
      task_id: Map.fetch!(task, :id),
      status: "pending",
      payload: task,
      overrides: overrides
    })
  end

  @doc """
  Builds insert attrs for `Records.Decision` from a `Router.Decision`,
  linked to `run_id`. `id` is set to `decision.decision_id` so the row's
  primary key matches the contract struct verbatim.
  """
  @spec decision_attrs(Ecto.UUID.t(), Decision.t()) :: map()
  def decision_attrs(run_id, %Decision{} = decision) do
    %{
      id: decision.decision_id,
      run_id: run_id,
      task_id: decision.task_id,
      target: decision.target,
      features: decision.features,
      decided_at: decision.decided_at
    }
  end

  @doc """
  Inserts a `Records.Decision` row for `decision`, linked to `run_id`.
  """
  @spec record_decision(Ecto.UUID.t(), Decision.t()) ::
          {:ok, DecisionRecord.t()} | {:error, Ecto.Changeset.t()}
  def record_decision(run_id, %Decision{} = decision) do
    run_id
    |> decision_changeset(decision)
    |> Repo.insert()
  end

  @doc """
  Builds an `Ecto.Changeset` for a `Records.Decision` insert, without
  touching the DB — for composing into an `Ecto.Multi` alongside other
  operations (e.g. atomically with an Oban job insert).
  """
  @spec decision_changeset(Ecto.UUID.t(), Decision.t()) :: Ecto.Changeset.t()
  def decision_changeset(run_id, %Decision{} = decision) do
    DecisionRecord.changeset(%DecisionRecord{}, decision_attrs(run_id, decision))
  end

  @doc """
  Reloads the `Records.Decision` row for `decision_id` and converts it back
  to the `Router.Decision` contract struct via `to_contract/1`.

  Raises `Ecto.NoResultsError` if no row matches `decision_id`.
  """
  @spec get_decision!(Ecto.UUID.t()) :: Decision.t()
  def get_decision!(decision_id) do
    DecisionRecord
    |> Repo.get!(decision_id)
    |> to_contract()
  end

  @doc """
  Looks up the `Records.Decision` row linked to `run_id`, or `nil` if none
  exists yet. `unique_index(:decisions, [:run_id])` makes this an
  idempotency check: a non-`nil` result means `run_id` has already been
  routed, so a replayed `RouteWorker` job can skip re-routing instead of
  hitting the unique constraint.
  """
  @spec get_decision_by_run(Ecto.UUID.t()) :: DecisionRecord.t() | nil
  def get_decision_by_run(run_id) do
    Repo.get_by(DecisionRecord, run_id: run_id)
  end

  @doc """
  Builds insert attrs for `Records.RunTask` from an `Executor.Result`,
  linked to `run_id` and `decision_id`. `output`, `duration_ms`, and
  `artifacts` are carried over verbatim. `target` and `rejected` carry
  over the fallback walk `Kapelle.Executor.Execution` recorded on
  `result` (REQ-104), so the audit trail shows which target actually
  served and why any earlier targets were passed over.
  """
  @spec run_task_attrs(Ecto.UUID.t(), Ecto.UUID.t(), Result.t()) :: map()
  def run_task_attrs(run_id, decision_id, %Result{} = result) do
    %{
      run_id: run_id,
      decision_id: decision_id,
      task_id: result.task_id,
      status: to_string(result.status),
      output: result.output,
      duration_ms: result.duration_ms,
      artifacts: result.artifacts,
      target: result.target,
      rejected: encode_rejected(result.rejected)
    }
  end

  # Reasons come from adapters and can be arbitrary terms (ChainAdapter can
  # emit `{:chain_exception, exception, stacktrace}`); jsonb only takes
  # JSON-safe values, so anything beyond an atom or a string is stored as
  # its `inspect/1` rendering — the audit trail keeps the information, the
  # insert can't crash a run whose fallback actually succeeded.
  defp encode_rejected(rejected) when is_list(rejected) do
    Enum.map(rejected, fn {id, reason} -> %{"id" => id, "reason" => encode_reason(reason)} end)
  end

  defp encode_reason(reason) when is_atom(reason), do: to_string(reason)
  defp encode_reason(reason) when is_binary(reason), do: reason
  defp encode_reason(reason), do: inspect(reason)

  @doc """
  Inserts a `Records.RunTask` row for `result`, linked to `run_id` and
  `decision_id`.
  """
  @spec record_run_task(Ecto.UUID.t(), Ecto.UUID.t(), Result.t()) ::
          {:ok, RunTask.t()} | {:error, Ecto.Changeset.t()}
  def record_run_task(run_id, decision_id, %Result{} = result) do
    %RunTask{}
    |> RunTask.changeset(run_task_attrs(run_id, decision_id, result))
    |> Repo.insert()
  end

  @doc """
  Reloads the `Records.RunTask` row for `run_task_id` and converts it back
  to the `Executor.Result` contract struct via `to_contract/1`.

  Raises `Ecto.NoResultsError` if no row matches `run_task_id`.
  """
  @spec get_run_task!(Ecto.UUID.t()) :: Result.t()
  def get_run_task!(run_task_id) do
    RunTask
    |> Repo.get!(run_task_id)
    |> to_contract()
  end

  @doc """
  Looks up the `Records.RunTask` row linked to `decision_id`, or `nil` if
  none exists yet. `unique_index(:run_tasks, [:decision_id])` makes this
  an idempotency check: a non-`nil` result means `decision_id` has
  already been executed, so a replayed `ExecuteWorker` job can skip
  re-execution instead of hitting the unique constraint.
  """
  @spec get_run_task_by_decision(Ecto.UUID.t()) :: RunTask.t() | nil
  def get_run_task_by_decision(decision_id) do
    Repo.get_by(RunTask, decision_id: decision_id)
  end

  @doc """
  Builds insert attrs for `Records.Verdict` from an `Evaluator.Verdict`,
  linked to `decision_id`. `score_components` is never dropped, matching
  the invariant `Evaluator.Verdict` itself enforces.
  """
  @spec verdict_attrs(Ecto.UUID.t(), Verdict.t()) :: map()
  def verdict_attrs(decision_id, %Verdict{} = verdict) do
    %{
      decision_id: decision_id,
      task_id: verdict.task_id,
      total_score: verdict.total_score,
      score_components: verdict.score_components
    }
  end

  @doc """
  Inserts a `Records.Verdict` row for `verdict`, linked to `decision_id`.

  Returns `{:error, :verdict_decision_mismatch}` without touching the DB if
  `verdict.decision_id` doesn't match `decision_id` — `verdict_attrs/2`
  always links the verdict row to `decision_id`, so a mismatched `verdict`
  would otherwise be silently persisted against the wrong decision.
  """
  @spec record_verdict(Ecto.UUID.t(), Verdict.t()) ::
          {:ok, VerdictRecord.t()}
          | {:error, :verdict_decision_mismatch}
          | {:error, Ecto.Changeset.t()}
  def record_verdict(decision_id, %Verdict{} = verdict) do
    if verdict.decision_id == decision_id do
      %VerdictRecord{}
      |> VerdictRecord.changeset(verdict_attrs(decision_id, verdict))
      |> Repo.insert()
    else
      {:error, :verdict_decision_mismatch}
    end
  end

  @doc """
  Looks up the `Records.Verdict` row linked to `decision_id`, or `nil` if
  none exists yet. `unique_index(:verdicts, [:decision_id])` makes this
  an idempotency check: a non-`nil` result means `decision_id` has
  already been evaluated, so a replayed `EvaluateWorker` job can skip
  re-evaluation instead of hitting the unique constraint.
  """
  @spec get_verdict_by_decision(Ecto.UUID.t()) :: VerdictRecord.t() | nil
  def get_verdict_by_decision(decision_id) do
    Repo.get_by(VerdictRecord, decision_id: decision_id)
  end

  @doc """
  Builds insert attrs for `Records.Outcome` from a `Router.Outcome`,
  linked to `decision_id`. `type` is stringified (`Records.Outcome.type`
  is a plain string column, matching the schema convention for enum-like
  fields elsewhere in this module).
  """
  @spec outcome_attrs(Ecto.UUID.t(), Outcome.t()) :: map()
  def outcome_attrs(decision_id, %Outcome{} = outcome) do
    %{
      decision_id: decision_id,
      task_id: outcome.task_id,
      type: to_string(outcome.type)
    }
  end

  @doc """
  Inserts a `Records.Outcome` row for `outcome`, linked to `decision_id`.

  Returns `{:error, :outcome_decision_mismatch}` without touching the DB if
  `outcome.decision_id` doesn't match `decision_id`, mirroring
  `record_verdict/2`'s guard against silently persisting against the wrong
  decision.
  """
  @spec record_outcome(Ecto.UUID.t(), Outcome.t()) ::
          {:ok, OutcomeRecord.t()}
          | {:error, :outcome_decision_mismatch}
          | {:error, Ecto.Changeset.t()}
  def record_outcome(decision_id, %Outcome{} = outcome) do
    if outcome.decision_id == decision_id do
      %OutcomeRecord{}
      |> OutcomeRecord.changeset(outcome_attrs(decision_id, outcome))
      |> Repo.insert()
    else
      {:error, :outcome_decision_mismatch}
    end
  end

  @doc """
  Looks up the `Records.Outcome` row linked to `decision_id`, or `nil` if
  none exists yet. `unique_index(:outcomes, [:decision_id])` makes this an
  idempotency check, same as `get_verdict_by_decision/1`.
  """
  @spec get_outcome_by_decision(Ecto.UUID.t()) :: OutcomeRecord.t() | nil
  def get_outcome_by_decision(decision_id) do
    Repo.get_by(OutcomeRecord, decision_id: decision_id)
  end

  @doc """
  Restores the atom-keyed shape `Pipeline.run_sync/2`'s in-memory `task`
  map has, from a `Run.payload` reloaded off a jsonb column (string keys,
  and `:type`'s value serialized to a string). Used by `RouteWorker`,
  `ExecuteWorker`, and `EvaluateWorker` so a submitted task is routed,
  executed, and evaluated identically whether it took the sync or async
  path.

  Returns `{:error, {:unknown_task_key, key}}` instead of raising if
  `payload` carries a key that isn't an existing atom anywhere in the app.
  `:type`'s value is left as a string if it isn't a known atom either,
  which policies already treat as an unroutable task shape.
  """
  @spec atomize_task(map()) :: {:ok, map()} | {:error, {:unknown_task_key, String.t()}}
  def atomize_task(payload) when is_map(payload) do
    payload
    |> Enum.reduce_while({:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_atom(key) ->
        {:cont, {:ok, Map.put(acc, key, value)}}

      {key, value}, {:ok, acc} ->
        case safe_to_existing_atom(key) do
          {:ok, atom_key} -> {:cont, {:ok, Map.put(acc, atom_key, value)}}
          :error -> {:halt, {:error, {:unknown_task_key, key}}}
        end
    end)
    |> case do
      {:ok, task} -> {:ok, atomize_type(task)}
      error -> error
    end
  end

  defp atomize_type(%{type: type} = task) when is_binary(type) do
    case safe_to_existing_atom(type) do
      {:ok, atom} -> %{task | type: atom}
      :error -> task
    end
  end

  defp atomize_type(task), do: task

  defp safe_to_existing_atom(string) when is_binary(string) do
    {:ok, String.to_existing_atom(string)}
  rescue
    ArgumentError -> :error
  end

  defp safe_to_existing_atom(_other), do: :error

  @doc """
  Converts a `Records.Decision` row back to the `Router.Decision` contract
  struct, or a `Records.RunTask` row back to the `Executor.Result` contract
  struct.
  """
  @spec to_contract(DecisionRecord.t()) :: Decision.t()
  @spec to_contract(RunTask.t()) :: Result.t()
  def to_contract(%DecisionRecord{} = decision) do
    Decision.new!(%{
      decision_id: decision.id,
      task_id: decision.task_id,
      target: atomize_target(decision.target),
      decided_at: decision.decided_at,
      features: decision.features
    })
  end

  def to_contract(%RunTask{} = run_task) do
    Result.new!(%{
      task_id: run_task.task_id,
      status: String.to_existing_atom(run_task.status),
      output: run_task.output,
      duration_ms: run_task.duration_ms,
      artifacts: run_task.artifacts,
      target: run_task.target,
      rejected: decode_rejected(run_task.rejected)
    })
  end

  defp atomize_target(%{"provider" => provider, "model" => model}) do
    %{provider: provider, model: model}
  end

  defp decode_rejected(rejected) when is_list(rejected) do
    Enum.map(rejected, fn %{"id" => id, "reason" => reason} -> {id, decode_reason(reason)} end)
  end

  defp decode_reason(reason) when is_binary(reason) do
    case safe_to_existing_atom(reason) do
      {:ok, atom} -> atom
      :error -> reason
    end
  end

  defp decode_reason(reason), do: reason
end
