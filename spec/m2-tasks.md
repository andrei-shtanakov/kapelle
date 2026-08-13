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
🟠 P1 | ⏸️ BLOCKED | Est: 1d

**Description:**
Close `decision_id → verdict → router outcome` exactly once: a typed outcome
persisted after a terminal verdict, idempotent redelivery, verdict and outcome
written atomically, a late event that never overwrites a terminal result, and
no false completion after a crash between steps.

**Checklist:**
- [ ] typed outcome persisted on a terminal verdict
- [ ] redelivery is idempotent
- [ ] verdict and outcome are atomic
- [ ] a late event does not overwrite a terminal result
- [ ] a crash between steps leaves no false completion

**Traces to:** [REQ-102]
**Depends on:** [TASK-101]
**Blocks:** [TASK-103]

### TASK-103: LiveView run detail
🟠 P1 | ⏸️ BLOCKED | Est: 1d

**Description:**
The first useful M3 page: a runs list and a detail view showing task, decision,
result/verdict and current status, updating over PubSub. Read-only in this
slice — cancel and retry are a separate task.

**Checklist:**
- [ ] runs list
- [ ] detail view with task, decision, result/verdict, status
- [ ] PubSub update on state change, no reload
- [ ] LiveView tests, no external network

**Traces to:** [REQ-103]
**Depends on:** [TASK-102]
**Blocks:** —
