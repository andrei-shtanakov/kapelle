defmodule Kapelle.Product.RunVerdict do
  @moduledoc """
  The two-axis verdict for one product loop (design doc §1; M3 exit
  criteria §9.3): **product** — what the loop produced — and **harness** —
  how this codebase's durable execution behaved while carrying it. The two
  never collapse into one value. `product: :pass, harness:
  :observability_gap` is a useful answer, and this module is shaped so it
  can be said out loud instead of being rounded up to "green".

  Neither axis judges proposal quality: the product axis reads the loop's
  own terminal lifecycle — the domain result the reference runner agrees
  on through the parity suite — and the harness axis reads execution facts:
  evidence integrity, discarded jobs, a terminal outcome that was reached
  but never recorded, and what this codebase cannot measure at all yet.

  ## Cost is allowed to say "unknown"

  `cost.tokens` is `nil` with a stated reason, never `0`. With
  fixture-backed agents (design §4) no model call happens, so a zero would
  be a lie shaped like a measurement — and the reason it is nil is exactly
  the `:cost_not_instrumented` harness finding that keeps the harness axis
  at `:observability_gap`. The gap is *derived* from the absent
  instrumentation rather than hardcoded: `token_usage/1` is the single seam
  a real provider adapter fills, and the day it returns figures the finding
  stops firing on its own.

  ## Interventions are counted from the loop's own evidence

  A consumed `loop-resume-decision` artifact is one human resume; an
  assumption carrying `human_waiver` in a stored concept draft is one human
  waiver. Holds are *derived* — `resumes + 1 if currently held` — because
  the loop lifecycle keeps no hold history table: each resume consumes
  exactly one hold, so the derivation is exact for every path the contour
  can produce today. It is stated here rather than hidden, because it stops
  being exact the moment a hold can be lifted by anything but a decision.

  Unknown is never reported as zero: when the view fails to build, the
  intervention counts come back `nil`, the same way `tokens` does.
  """

  import Ecto.Query, only: [from: 2]

  alias Kapelle.Product.{Loops, NextStage, Store, View}
  alias Kapelle.Product.Records.LoopRow
  alias Kapelle.Repo

  @type product_axis :: :pass | :fail | :blocked | :open | :unknown
  @type harness_axis :: :pass | :observability_gap | :fail

  @type finding :: %{class: atom(), severity: :fail | :gap, detail: term()}

  @type t :: %__MODULE__{
          loop_id: String.t(),
          product: product_axis(),
          product_reason: String.t(),
          harness: harness_axis(),
          harness_findings: [finding()],
          cost: map(),
          interventions: map()
        }

  @enforce_keys [:loop_id, :product, :product_reason, :harness, :cost, :interventions]
  defstruct [
    :loop_id,
    :product,
    :product_reason,
    :harness,
    :cost,
    :interventions,
    harness_findings: []
  ]

  # Oban states a job can still leave on its own. A loop whose walk is
  # already terminal while one of these is queued is mid-flight, not
  # stalled — the distinction `:terminal_not_recorded` rests on.
  @runnable_states ~w(available scheduled executing retryable)

  @doc """
  Builds the two-axis verdict for `loop_id`, or `{:error, :not_found}`.

  Read-only: it starts no work, records nothing, and repairs nothing — an
  observation of a loop must never be able to change it.
  """
  @spec for_loop(String.t()) :: {:ok, t()} | {:error, :not_found}
  def for_loop(loop_id) when is_binary(loop_id) do
    case Loops.fetch(loop_id) do
      :error -> {:error, :not_found}
      {:ok, loop} -> {:ok, build(loop)}
    end
  end

  defp build(%LoopRow{loop_id: loop_id} = loop) do
    view_result = View.build(loop_id)
    jobs = job_facts(loop_id)
    rows = Store.all(loop_id)

    {product, product_reason} = product_axis(loop, view_result)
    findings = harness_findings(loop, view_result, jobs)

    %__MODULE__{
      loop_id: loop_id,
      product: product,
      product_reason: product_reason,
      harness: harness_axis(findings),
      harness_findings: findings,
      cost: cost(loop, jobs, rows, view_result),
      interventions: interventions(loop, rows, view_result)
    }
  end

  # --- product axis: the loop's own lifecycle, nothing else ---

  defp product_axis(_loop, {:error, reason}) do
    {:unknown, "evidence unreadable: #{inspect(reason)}"}
  end

  defp product_axis(%LoopRow{status: "ready"} = loop, _view) do
    {:pass, loop.stop_reason || "ready_for_business"}
  end

  defp product_axis(%LoopRow{status: "failed"} = loop, _view) do
    {:fail, loop.stop_reason || "failed"}
  end

  defp product_axis(%LoopRow{status: "needs_human"} = loop, _view) do
    {:blocked, loop.stop_reason || "needs_human"}
  end

  defp product_axis(%LoopRow{status: "running"} = loop, {:ok, view}) do
    case NextStage.compute(view, loop.max_iterations) do
      {:run, {stage, iteration}} -> {:open, "pending #{stage} at iteration #{iteration}"}
      {:terminal, verdict, reason} -> {:open, "walk is terminal (#{verdict}): #{reason}"}
    end
  end

  # --- harness axis: execution facts, and what cannot be measured ---

  defp harness_findings(loop, view_result, jobs) do
    evidence_findings(view_result) ++
      job_findings(jobs) ++
      recording_findings(loop, view_result, jobs) ++
      instrumentation_findings(loop.loop_id)
  end

  defp evidence_findings({:error, reason}) do
    [%{class: :evidence_unreadable, severity: :fail, detail: reason}]
  end

  defp evidence_findings({:ok, %View{dropped: []}}), do: []

  # A dropped row is a stored artifact that no longer passes its own
  # checks. `View` keeps the loop readable past it by design; for the
  # harness it is integrity damage and reads as a failure.
  defp evidence_findings({:ok, %View{dropped: dropped}}) do
    [%{class: :artifacts_dropped, severity: :fail, detail: dropped}]
  end

  # Only `discarded` counts as loss: Oban discards after retries are
  # exhausted, which is work this harness gave up on. A `cancelled` job is
  # the opposite — the deliberate `{:cancel, reason}` a stage returns when
  # it refuses an invalid artifact fail-closed. Counting cancellations as
  # damage would report the fail-closed contour working exactly as designed
  # (the invalid-artifact golden) as a harness failure; they are recorded in
  # `cost.cancelled_jobs` as the fact they are.
  defp job_findings(%{discarded: 0}), do: []

  defp job_findings(%{discarded: discarded}) do
    [%{class: :jobs_discarded, severity: :fail, detail: discarded}]
  end

  # A `running` loop with nothing left that could move it is stalled, and
  # which kind of stall it is matters: either the walk already reached a
  # terminal verdict that never made it into the lifecycle (the result
  # exists in the evidence and no one recorded it), or a stage is still
  # owed and no job will ever run it. Both are durability failures of this
  # harness; a running loop with runnable jobs is simply mid-flight.
  defp recording_findings(%LoopRow{status: "running"} = loop, {:ok, view}, %{runnable: 0}) do
    case NextStage.compute(view, loop.max_iterations) do
      {:terminal, verdict, _reason} ->
        [%{class: :terminal_not_recorded, severity: :fail, detail: verdict}]

      {:run, {stage, iteration}} ->
        [%{class: :stalled, severity: :fail, detail: %{stage: stage, iteration: iteration}}]
    end
  end

  defp recording_findings(_loop, _view_result, _jobs), do: []

  defp instrumentation_findings(loop_id) do
    case token_usage(loop_id) do
      nil -> [%{class: :cost_not_instrumented, severity: :gap, detail: :tokens}]
      _usage -> []
    end
  end

  defp harness_axis(findings) do
    cond do
      Enum.any?(findings, &(&1.severity == :fail)) -> :fail
      Enum.any?(findings, &(&1.severity == :gap)) -> :observability_gap
      true -> :pass
    end
  end

  # The seam a real provider adapter fills (design §9: real adapters are
  # out of M3). Until one reports usage there is nothing to read, and
  # saying so is the whole point — see the moduledoc.
  defp token_usage(_loop_id), do: nil

  # --- cost per run ---

  defp cost(loop, jobs, rows, view_result) do
    %{
      iterations_used: iterations_used(view_result),
      max_iterations: loop.max_iterations,
      stage_jobs: jobs.total,
      attempts: jobs.attempts,
      retries: jobs.retries,
      discarded_jobs: jobs.discarded,
      cancelled_jobs: jobs.cancelled,
      artifact_revisions: length(rows),
      wall_ms: jobs.wall_ms,
      tokens: token_usage(loop.loop_id),
      tokens_unavailable: tokens_unavailable(loop.loop_id)
    }
  end

  defp tokens_unavailable(loop_id) do
    if token_usage(loop_id) == nil, do: :not_instrumented
  end

  defp iterations_used({:error, _reason}), do: nil

  defp iterations_used({:ok, view}) do
    case Map.keys(view.research_packs) do
      [] -> 0
      iterations -> Enum.max(iterations) + 1
    end
  end

  # --- interventions per run ---

  defp interventions(loop, rows, {:ok, view}) do
    resume_refs = resume_refs(rows)
    waiver_refs = waiver_refs(view)

    %{
      holds: length(resume_refs) + held(loop),
      resumes: length(resume_refs),
      resume_refs: resume_refs,
      waivers: length(waiver_refs),
      waiver_refs: waiver_refs
    }
  end

  # Unknown, not zero: without a readable view the waivers cannot be seen,
  # and a half-counted intervention tally is worse than an absent one.
  defp interventions(_loop, _rows, {:error, _reason}) do
    %{holds: nil, resumes: nil, resume_refs: nil, waivers: nil, waiver_refs: nil}
  end

  defp held(%LoopRow{status: "needs_human"}), do: 1
  defp held(%LoopRow{}), do: 0

  defp resume_refs(rows) do
    rows
    |> Enum.filter(&(&1.kind == :loop_resume_decision))
    |> Enum.map(&"loop-resume-decision://#{&1.id}")
    |> Enum.sort()
  end

  defp waiver_refs(%View{concept_drafts: drafts}) do
    drafts
    |> Enum.flat_map(fn {_iteration, draft} ->
      draft
      |> Map.get("assumptions", [])
      |> Enum.filter(&(&1["human_waiver"] not in [nil, ""]))
      |> Enum.map(fn _assumption -> "concept-draft://#{draft["id"]}" end)
    end)
    |> Enum.sort()
  end

  # --- job facts ---

  defp job_facts(loop_id) do
    jobs =
      Repo.all(
        from(j in Oban.Job,
          where: fragment("? ->> 'loop_id' = ?", j.args, ^loop_id),
          select: %{
            state: j.state,
            attempt: j.attempt,
            inserted_at: j.inserted_at,
            completed_at: j.completed_at
          }
        )
      )

    %{
      total: length(jobs),
      attempts: Enum.sum(Enum.map(jobs, &(&1.attempt || 0))),
      retries: Enum.sum(Enum.map(jobs, &max((&1.attempt || 0) - 1, 0))),
      discarded: Enum.count(jobs, &(&1.state == "discarded")),
      cancelled: Enum.count(jobs, &(&1.state == "cancelled")),
      runnable: Enum.count(jobs, &(&1.state in @runnable_states)),
      wall_ms: wall_ms(jobs)
    }
  end

  defp wall_ms(jobs) do
    starts = Enum.map(jobs, & &1.inserted_at)
    finishes = jobs |> Enum.map(& &1.completed_at) |> Enum.reject(&is_nil/1)

    if starts == [] or finishes == [] do
      nil
    else
      NaiveDateTime.diff(
        Enum.max(finishes, NaiveDateTime),
        Enum.min(starts, NaiveDateTime),
        :millisecond
      )
    end
  end
end
