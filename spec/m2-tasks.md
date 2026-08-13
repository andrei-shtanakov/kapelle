# Kapelle — Tasks (Phase 2: M2/M3)

> Run with `--spec-prefix=m2-`. Phase 1 (`spec/tasks.md`) is closed and is left
> untouched.
>
> These three run under `execution_mode: tdd` and are the evidence set for the
> spec-runner TDD lifecycle. They are executed **one at a time**, each with its
> own evidence record; they are not a DAG to be run unattended.

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
🟠 P1 | ⬜ TODO | Est: 1d

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
- [ ] one shared execution seam walks `[decision target | fallback]` via `FallbackResolver.resolve/2`; `Pipeline.run_sync/2` and `ExecuteWorker` both go through it
- [ ] a provider `:error` on the routed target executes the next declared target; `:fail` is returned as-is and never falls back
- [ ] all targets erroring ends the run `failed` with the typed `{:all_targets_errored, rejections}` reason — no crash, no retry storm
- [ ] `run_tasks` persists `target` and the ordered `rejected` history; `to_contract/1` restores them onto `Executor.Result`
- [ ] cycle detection order is deterministic (no dependence on map iteration order)
- [ ] the reported cycle is the minimal cycle segment, with a regression test for an entry leading into a cycle it is not part of
- [ ] integration test through the real runtime entrypoint (submit → route → execute → persisted rows), not a direct resolver call
- [ ] no test performs network I/O

**Traces to:** [REQ-104]
**Depends on:** [TASK-101]
**Blocks:** —
