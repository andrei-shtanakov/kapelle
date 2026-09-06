defmodule Kapelle.Product.RunVerdict do
  @moduledoc """
  The two-axis verdict for one product loop (design doc §1; M3 exit
  criteria §9.3): **product** — what the loop produced — and **harness** —
  how this codebase's durable execution behaved while carrying it. The two
  never collapse into one value: `product: :pass, harness: :fail` on a
  loop whose result is right but whose executing row was orphaned is a
  useful answer, and this module is shaped so it can be said out loud
  instead of being rounded up to "green". `harness: :observability_gap`
  is the same kind of answer: no fixture-backed run in M3 reaches it, and
  an agent address this slice does not know does — see the cost table
  below.

  Neither axis judges proposal quality: the product axis reads the loop's
  own terminal lifecycle — the domain result the reference runner agrees
  on through the parity suite — and the harness axis reads execution facts:
  evidence integrity, discarded jobs, and a terminal outcome that was
  reached but never recorded.

  ## Cost keeps three token states apart

  `cost.tokens` is `nil` with a stated reason, never `0`. With
  fixture-backed agents (design §4) no model call happens, so a zero would
  be a lie shaped like a measurement. Three states must stay
  distinguishable, and collapsing any two of them loses a real fact
  (owner ruling 2026-09-06):

  | state | `tokens` | reason | finding |
  |---|---|---|---|
  | no usage, and the loop's agent is a recognised fixture address | `nil` | `:not_applicable` | `:cost_not_applicable`, severity `:info` |
  | usage reported, including nothing spent | the figure, `0` included | — | none |
  | no usage, and the agent is anything else | `nil` | `:not_instrumented` | `:cost_not_instrumented`, severity `:gap` |

  Only the third is an observability gap. "No provider was called" is not
  a loss of visibility into a cost that exists — there is no such cost —
  so it is recorded as evidence and costs the harness axis nothing.
  Recording it still matters: without the note, a run with no provider
  would be indistinguishable from one whose spend was measured.

  The first state is decided by `Agent.fixture?/1` on the loop's own
  address, never by the absence of a figure, and that direction is
  load-bearing: a live scheme added by #50 without instrumentation lands
  in the third state and turns the axis red, instead of claiming the
  provider was never called. `token_usage/1` is the single seam a real
  adapter fills; M3 only ever reaches the first state, because
  `fixture:<key>` is the only address `Agent.resolve!/1` knows.

  The state is computed once (`token_state/1`) and shared by the finding
  and the cost block: reading the same fact twice is two chances to
  disagree, and the note and the number must tell one story.

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

  ## A `failed` loop is not automatically a product failure

  `Kapelle.Product.Loops`'s `status`/`stop_reason` are this codebase's own
  lifecycle, not the producer's verdict — and `StageShell` writes `failed`
  for two very different things: the agent or its output was bad (a domain
  refusal, `{:domain, …}` / `{:invalid_artifact, …}`), or *this harness*
  could not carry the loop — a crash between `Loops.create/1` and the
  idea's own write that `Reconciler` later finds as `{:view_incomplete,
  :idea_missing}`, a projection drift, a chain violation. Charging the
  second kind to the product axis would blame the proposal for a durability
  failure, which is the exact confusion this module exists to prevent.

  The reason is matched as text because that is how the lifecycle stores it
  (`inspect/1` of a tuple), and the match is deliberately conservative:
  only the two shapes the stage shell writes for domain refusals count as a
  product failure. An unrecognised — or absent — reason is charged to the
  harness, so a new failure shape shows up as a harness finding to be
  classified rather than as a silent, clean-looking product verdict.
  """

  import Ecto.Query, only: [from: 2]

  alias Kapelle.Product.{Agent, Loops, NextStage, Store, View}
  alias Kapelle.Product.Records.LoopRow
  alias Kapelle.Repo

  @type product_axis :: :pass | :fail | :blocked | :open | :unknown
  @type harness_axis :: :pass | :observability_gap | :fail

  @type finding :: %{class: atom(), severity: :fail | :gap | :info, detail: term()}

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

  # States from which Oban moves a job on its own. `executing` is
  # deliberately NOT here: this app configures no `Oban.Plugins.Lifeline`
  # (config/config.exs), and `StageShell`'s own contract records the
  # consequence — a raw BEAM crash mid-`perform/1` leaves the row in
  # `executing` forever. Counting such a row as "will still run" would let
  # a permanently stalled loop report a clean `harness: :pass` — precisely
  # the harness failure this module exists to name, silenced.
  @runnable_states ~w(available scheduled retryable)

  # Past this age an `executing` row stops being a credible reading of live
  # work. The number is not a rescue window — nothing rescues these rows
  # here — it is the point where "still running" becomes the less likely
  # explanation than "the node died holding it". 60 minutes matches Oban's
  # own Lifeline `rescue_after` default, so an app that later adds the
  # plugin inherits a consistent boundary. Override with
  # `config :kapelle, orphaned_job_after_ms: …`.
  @default_orphaned_after_ms 60 * 60 * 1000

  # The same question the orphan threshold answers — live window or dead
  # loop? — applies to a `running` loop with nothing runnable, and it was
  # missing here. Two ordinary windows produce exactly that shape:
  # `Loop.start/2` is not transactional (the config row exists before the
  # first job is enqueued), and a job can finish between this module's own
  # reads. Neither is a durability failure, and calling them one would make
  # the loudest finding this module has the one it cries most often.
  # Measured from the loop row's own `updated_at`, which every lifecycle and
  # projection write touches.
  @default_stalled_after_ms 60 * 1000

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

  defp build(%LoopRow{loop_id: loop_id} = initial_loop) do
    view_result = View.build(loop_id)
    jobs = job_facts(loop_id)
    rows = Store.all(loop_id)

    # Re-read the lifecycle AFTER the facts, never before: these are four
    # separate queries with no shared snapshot, and the loop can finish
    # between them. Judging by the row read first would report the stale
    # `running` — the loudest possible verdict — for a loop that simply
    # completed while being looked at.
    loop = refresh(initial_loop)

    {product, product_reason} = product_axis(loop, view_result)
    token_state = token_state(loop)
    findings = harness_findings(loop, view_result, jobs, token_state)

    %__MODULE__{
      loop_id: loop_id,
      product: product,
      product_reason: product_reason,
      harness: harness_axis(findings),
      harness_findings: findings,
      cost: cost(loop, jobs, rows, view_result, token_state),
      interventions: interventions(loop, rows, view_result)
    }
  end

  defp refresh(%LoopRow{loop_id: loop_id} = loop) do
    case Loops.fetch(loop_id) do
      {:ok, fresh} -> fresh
      :error -> loop
    end
  end

  # --- product axis: the loop's own lifecycle, nothing else ---

  defp product_axis(_loop, {:error, reason}) do
    {:unknown, "evidence unreadable: #{inspect(reason)}"}
  end

  defp product_axis(%LoopRow{status: "ready"} = loop, _view) do
    {:pass, loop.stop_reason || "ready_for_business"}
  end

  defp product_axis(%LoopRow{status: "failed"} = loop, _view) do
    if domain_failure?(loop.stop_reason) do
      {:fail, loop.stop_reason}
    else
      {:unknown, "lifecycle failed off the domain: #{loop.stop_reason || "(no reason recorded)"}"}
    end
  end

  defp product_axis(%LoopRow{status: "needs_human"} = loop, _view) do
    {:blocked, loop.stop_reason || "needs_human"}
  end

  # A loop whose lifecycle still says `running` is judged on its evidence,
  # not on whether the write landed: the artifacts already decide the
  # domain verdict, and `NextStage.compute/2` is the same walk the
  # reference runner agrees with through the parity suite. A crash between
  # the final artifact and the status write must cost the harness its axis
  # (`:terminal_not_recorded`) without also demoting a produced result to
  # "still open" — one infrastructure fault, one axis.
  defp product_axis(%LoopRow{status: "running"} = loop, {:ok, view}) do
    case NextStage.compute(view, loop.max_iterations) do
      {:run, {stage, iteration}} ->
        {:open, "pending #{stage} at iteration #{iteration}"}

      {:terminal, :ready, reason} ->
        {:pass, reason <> " (not recorded in the lifecycle)"}

      {:terminal, :needs_human, reason} ->
        {:blocked, reason <> " (not recorded in the lifecycle)"}
    end
  end

  # --- harness axis: execution facts, and what cannot be measured ---

  defp harness_findings(loop, view_result, jobs, token_state) do
    lifecycle_findings(loop) ++
      evidence_findings(view_result) ++
      job_findings(jobs) ++
      orphan_findings(jobs) ++
      recording_findings(loop, view_result, jobs) ++
      token_usage_findings(token_state)
  end

  # `failed` for anything but a domain refusal is this harness failing to
  # carry the loop — recovery included, since `Reconciler` writing
  # `{:view_incomplete, …}` IS the recovery path reporting it could not
  # rebuild the run.
  defp lifecycle_findings(%LoopRow{status: "failed"} = loop) do
    if domain_failure?(loop.stop_reason) do
      []
    else
      [%{class: :lifecycle_failed_off_domain, severity: :fail, detail: loop.stop_reason}]
    end
  end

  defp lifecycle_findings(%LoopRow{}), do: []

  # The two reason shapes `StageShell` writes when the DOMAIN refused: a
  # stage's `{:domain, reason}` and its `{:invalid_artifact, reason}`.
  defp domain_failure?(nil), do: false

  defp domain_failure?(stop_reason) do
    String.starts_with?(stop_reason, ["{:domain,", "{:invalid_artifact,"])
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

  # An `executing` row older than the orphan threshold is work no one will
  # ever finish: without Lifeline nothing moves it, and no retry is
  # scheduled. Reported whatever the loop's own status says — a stuck row
  # under a loop that reached its verdict some other way is still a
  # durability failure, just one that stopped being visible in the domain.
  defp orphan_findings(%{orphaned: 0}), do: []

  defp orphan_findings(%{orphaned: orphaned}) do
    [%{class: :jobs_orphaned, severity: :fail, detail: orphaned}]
  end

  # A `running` loop with nothing left that could move it is stalled, and
  # which kind of stall it is matters: either the walk already reached a
  # terminal verdict that never made it into the lifecycle (the result
  # exists in the evidence and no one recorded it), or a stage is still
  # owed and no job will ever run it. Both are durability failures of this
  # harness; a running loop with runnable jobs is simply mid-flight.
  defp recording_findings(
         %LoopRow{status: "running"} = loop,
         {:ok, view},
         %{runnable: 0, executing: 0}
       ) do
    if settled_long_enough?(loop), do: stall_finding(loop, view), else: []
  end

  defp recording_findings(_loop, _view_result, _jobs), do: []

  defp stall_finding(loop, view) do
    case NextStage.compute(view, loop.max_iterations) do
      {:terminal, verdict, _reason} ->
        [%{class: :terminal_not_recorded, severity: :fail, detail: verdict}]

      {:run, {stage, iteration}} ->
        [%{class: :stalled, severity: :fail, detail: %{stage: stage, iteration: iteration}}]
    end
  end

  # A row with no `updated_at` cannot be aged; like an `executing` row
  # without `attempted_at`, that makes it less accountable, not more.
  defp settled_long_enough?(%LoopRow{updated_at: nil}), do: true

  defp settled_long_enough?(%LoopRow{updated_at: updated_at}) do
    NaiveDateTime.diff(NaiveDateTime.utc_now(), updated_at, :millisecond) > stalled_after_ms()
  end

  defp stalled_after_ms do
    Application.get_env(:kapelle, :stalled_loop_after_ms, @default_stalled_after_ms)
  end

  defp token_usage_findings({:unavailable, :not_applicable}) do
    [%{class: :cost_not_applicable, severity: :info, detail: :no_provider_call}]
  end

  defp token_usage_findings({:unavailable, :not_instrumented}) do
    [%{class: :cost_not_instrumented, severity: :gap, detail: :tokens}]
  end

  defp token_usage_findings({:measured, _usage}), do: []

  @doc """
  Maps harness findings to the public axis without rounding gaps up to pass.
  Public so the two-axis contract stays testable directly: the ordering of
  `:fail` over `:gap` is a contract no single run demonstrates.

  `:info` findings are evidence, not defects: they are reported and
  deliberately do not lower the axis. A future edit that "fixes" this by
  degrading the axis on every note would erase the very distinction the
  cost table above exists to hold.
  """
  @spec harness_axis([finding()]) :: harness_axis()
  def harness_axis(findings) do
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

  defp cost(loop, jobs, rows, view_result, token_state) do
    %{
      iterations_used: iterations_used(view_result),
      max_iterations: loop.max_iterations,
      stage_jobs: jobs.total,
      attempts: jobs.attempts,
      retries: jobs.retries,
      discarded_jobs: jobs.discarded,
      cancelled_jobs: jobs.cancelled,
      executing_jobs: jobs.executing,
      orphaned_jobs: jobs.orphaned,
      artifact_revisions: length(rows),
      wall_ms: jobs.wall_ms,
      tokens: token_figure(token_state),
      tokens_unavailable: token_reason(token_state)
    }
  end

  # The one reading of the token fact, shared by the finding and the cost
  # block. Fail closed on the address: only a recognised fixture agent
  # proves that no provider was reached. Anything else — a live scheme,
  # a typo, an address this slice never knew — means the usage was owed
  # and never arrived, which is a real observability gap.
  defp token_state(%LoopRow{} = loop) do
    case token_usage(loop.loop_id) do
      nil ->
        if Agent.fixture?(loop.agent),
          do: {:unavailable, :not_applicable},
          else: {:unavailable, :not_instrumented}

      usage ->
        {:measured, usage}
    end
  end

  defp token_figure({:measured, usage}), do: usage
  defp token_figure({:unavailable, _reason}), do: nil

  defp token_reason({:measured, _usage}), do: nil
  defp token_reason({:unavailable, reason}), do: reason

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
            attempted_at: j.attempted_at,
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
      executing: Enum.count(jobs, &(&1.state == "executing")),
      orphaned: Enum.count(jobs, &orphaned?/1),
      wall_ms: wall_ms(jobs)
    }
  end

  # An `executing` row with no `attempted_at` cannot be aged at all, which
  # makes it less accountable than a merely stale one — not more.
  defp orphaned?(%{state: "executing", attempted_at: nil}), do: true

  # `Oban.Job` timestamps are `:utc_datetime_usec`, so these arrive as
  # `DateTime` structs; the `NaiveDateTime` calendar functions accept them
  # (both sides are UTC) and matching the struct name would silently miss.
  defp orphaned?(%{state: "executing", attempted_at: attempted_at}) do
    NaiveDateTime.diff(NaiveDateTime.utc_now(), attempted_at, :millisecond) > orphaned_after_ms()
  end

  defp orphaned?(_job), do: false

  defp orphaned_after_ms do
    Application.get_env(:kapelle, :orphaned_job_after_ms, @default_orphaned_after_ms)
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
