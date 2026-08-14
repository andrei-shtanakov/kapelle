# Kapelle — Tasks (Phase 2: M2/M3)

> Run with `--spec-prefix=m2-`. Phase 1 (`spec/tasks.md`) is closed and is left
> untouched.
>
> These tasks run under `execution_mode: tdd` and are the evidence set for the
> spec-runner TDD lifecycle: the original three shapes (domain logic,
> transactional persistence, read-model/UI) plus TASK-104, a wiring follow-up
> from PR #7's review. They are executed **one at a time**, each with its own
> evidence record; they are not a DAG to be run unattended.

**Legend:** 🔴 P0 · 🟠 P1 | ⬜ TODO · 🔄 IN PROGRESS · ✅ DONE · ⏸️ BLOCKED

## Milestone 2: Routing and feedback

### TASK-101: Deterministic provider fallback
🟠 P1 | ✅ DONE | Est: 0.5d

**Description:**
Give each catalog entry an optional, data-declared fallback chain, and make the
router walk it when a provider *errors*. Pure domain logic: no network, no new
process, no schema change.

The chain lives in `priv/catalog/models.toml` (a `fallback` list of
`"<provider>@<model>"` ids on an entry), is validated when the catalog is
loaded by `Kapelle.Providers.Catalog.load/1`, and is walked in order until one
target serves the request.

Two distinctions carry the task, and both already exist in
`Kapelle.Executor.Result`: `:error` means the provider itself failed, and is
the only thing that triggers a fallback; `:fail` means the provider answered
and the answer was a failure, which is a **result**, not a reason to try
someone else.

Validation is all-or-nothing at load time, matching `Catalog.load/1`'s existing
posture: a chain naming an unknown id, or one that cycles, makes the whole load
return `{:error, reason}`. Discovering either at call time would turn a data
mistake into a runtime surprise.

The `Result` must record which target actually served, and why each earlier
target was passed over, in order — a fallback that hides its own path cannot be
debugged from a log.

**Checklist:**
- [x] `fallback` is an optional list of ids on a catalog entry, parsed into `Kapelle.Providers.Catalog.Entry`
- [x] `Catalog.load/1` rejects an unknown fallback target: `{:error, {:unknown_fallback, id, target}}`
- [x] `Catalog.load/1` rejects a cycle: `{:error, {:fallback_cycle, [ids]}}`
- [x] resolution walks the chain in order and stops at the first target that does not `:error`
- [x] `:fail` is returned as-is and never triggers a fallback
- [x] the served target and the ordered rejection reasons are on the `Result`
- [x] table-driven unit tests covering: no chain, one hop, several hops, all targets erroring, `:fail` on the first target, unknown target, cycle
- [x] no test performs network I/O

**Traces to:** [REQ-101]
**Depends on:** —
**Blocks:** [TASK-102]

### TASK-102: Outcome feedback is transactional
🟠 P1 | ✅ DONE | Est: 1d

**Description:**
Close `decision_id → verdict → router outcome` exactly once: a typed outcome
persisted after a terminal verdict, idempotent redelivery, verdict and outcome
written atomically, a late event that never overwrites a terminal result, and
no false completion after a crash between steps.

**Checklist:**
- [x] typed outcome persisted on a terminal verdict
- [x] redelivery is idempotent
- [x] verdict and outcome are atomic
- [x] a late event does not overwrite a terminal result
- [x] a crash between steps leaves no false completion

**Traces to:** [REQ-102]
**Depends on:** [TASK-101]
**Blocks:** [TASK-103]

### TASK-103: LiveView run detail
🟠 P1 | ✅ DONE | Est: 1d

**Description:**
The first useful M3 page: a runs list and a detail view showing task, decision,
result/verdict and current status, updating over PubSub. Read-only in this
slice — cancel and retry are a separate task.

**Checklist:**
- [x] runs list
- [x] detail view with task, decision, result/verdict, status
- [x] PubSub update on state change, no reload
- [x] LiveView tests, no external network

**Traces to:** [REQ-103]
**Depends on:** [TASK-102]
**Blocks:** —

### TASK-104: Wire the fallback chain into routed execution
🟠 P1 | ✅ DONE | Est: 1d

**Description:**
Close the gap review found on PR #7: `Kapelle.Executor.FallbackResolver`
exists and is tested, but nothing in routed execution calls it — both
`Pipeline.run_sync/2` and `ExecuteWorker` call `adapter.execute(task,
decision)` exactly once, so REQ-101's runtime guarantee ("the router must
fall back along a declared chain on provider `:error`") does not actually
hold. Wire the resolver into both execution paths through one shared seam,
so the sync and async paths keep identical semantics (the same principle
`Persistence` already states for writes).

The walk must be visible in the audit trail: persist `Result.target` and
`Result.rejected` on the `run_tasks` row (`Persistence.run_task_attrs/3`
currently drops both) and carry them back out of `to_contract/1`, so a
reloaded `Result` still shows who served and why earlier targets were
passed over.

Two load-time validation fixes from the same review ride along, because
they concern the same chain data: cycle detection must not depend on map
iteration order, and the reported cycle must be the minimal cycle segment
(`A → B → C → B` reports `[B, C, B]`, not `[A, B, C, B]`).

**Checklist:**
- [x] one shared execution seam walks `[decision target | fallback]` via `FallbackResolver.resolve/2`; `Pipeline.run_sync/2` and `ExecuteWorker` both go through it
- [x] a provider `:error` on the routed target executes the next declared target; `:fail` is returned as-is and never falls back
- [x] all targets erroring ends the run `failed` with the typed `{:all_targets_errored, rejections}` reason — no crash, no retry storm
- [x] `run_tasks` persists `target` and the ordered `rejected` history; `to_contract/1` restores them onto `Executor.Result`
- [x] cycle detection order is deterministic (no dependence on map iteration order)
- [x] the reported cycle is the minimal cycle segment, with a regression test for an entry leading into a cycle it is not part of
- [x] integration test through the real runtime entrypoint (submit → route → execute → persisted rows), not a direct resolver call
- [x] no test performs network I/O

**Traces to:** [REQ-104]
**Depends on:** [TASK-101]
**Blocks:** —

---

### TASK-105: Needs-human hold path with inspectable state
🟠 P1 | 🔄 IN_PROGRESS | Est: 1d

The happy path lands on `ready_for_business`; the other terminal branch has
never been walked through the contour. `NextStage` already computes
`{:terminal, :needs_human, reason}` — what does not exist is the behaviour
around it: the evaluator moving the loop into `needs_human`, the state and its
causal artifacts being inspectable through the canonical `View`, the queue
staying empty afterwards, and a repeated reconcile neither duplicating nor
advancing anything.

This is a **hold**, not a failure: the loop stops and waits for a person, with
everything that person needs to decide already on the record.

Scope is one scenario, deliberately: the fixture agent produces a proposal
carrying a **critical unresolved gap/assumption**, and the loop holds. Not a
matrix, not a resume.

**Checklist:**
- [ ] the fixture agent has a deterministic needs-human script: a proposal with a critical gap/assumption the concept draft does not address
- [ ] the evaluator walks that scenario to `needs_human` through the ordinary worker contour, not by a direct `NextStage` call
- [ ] the loop's terminal status and the artifacts that caused it are readable through the canonical `View` — a person can see *why* it holds without reading the database
- [ ] no next job is enqueued once the loop holds
- [ ] a second reconcile reports `in_sync`: no duplicate artifacts, no events, no jobs, no advancement
- [ ] the domain observations match the golden oracle for the needs-human case
- [ ] no test performs network I/O, and no test invokes a live producer

**Out of scope, each for a reason:**
- **human resume** — blocked by the producer-owned contract (impresario#14); the contract does not exist yet, so there is nothing to port
- the full fault-injection matrix through the contour
- LiveView for the product surface
- a real LLM anywhere in the path
- any second S4 scenario

**Depends on:** [TASK-104]
**Blocks:** —
