# Kapelle — Tasks (Phase 1: M1 Vertical Slice)

> **ID mapping:** the spec-runner parser requires the `TASK-` prefix, so battle-
> testing backlog ids map as KAP-00N ≡ TASK-00N. TASK-001 (≡ KAP-001, manual
> bootstrap) is recorded for traceability only — it was executed by hand and is
> excluded from spec-runner statistics.

**Legend:** 🔴 P0 · 🟠 P1 | ⬜ TODO · 🔄 IN PROGRESS · ✅ DONE · ⏸️ BLOCKED

## Milestone 1: Vertical Slice

### TASK-001: Phoenix skeleton and test baseline
🔴 P0 | ✅ DONE | Est: 1d

**Description:**
Manual bootstrap (S0): Phoenix 1.8.9 + Oban + langchain + CI, green precommit
gate. Done 2026-08-04, commits `ae91857` + `24fbb0d`.

**Checklist:**
- [x] phx.new into existing repo, .tool-versions, deps
- [x] Oban migration + supervision, test mode :manual
- [x] CI with postgres service; mix precommit incl. credo

**Traces to:** [NFR-001]
**Depends on:** —
**Blocks:** [TASK-002]

### TASK-002: Contract structs Decision, Result, Verdict
🔴 P0 | ✅ DONE | Est: 0.5d

**Description:**
Create the three contract structs with validating constructors and typespecs,
per DESIGN-001. Pure structs, no Ecto, no network. This is the seam every other
context builds on.

**Checklist:**
- [x] `Kapelle.Router.Decision` (`lib/kapelle/router/decision.ex`): enforced keys decision_id/task_id/target/decided_at, features map, `@type t`, `new!/1` validating target shape
- [x] `Kapelle.Executor.Result` (`lib/kapelle/executor/result.ex`): status limited to :pass | :fail | :error, `new!/1` rejects unknown status
- [x] `Kapelle.Evaluator.Verdict` (`lib/kapelle/evaluator/verdict.ex`): enforced decision_id/task_id/total_score, score_components map defaults to %{} but is never dropped by any function
- [x] Unit tests for all three: happy path + missing key raises + invalid status/target raises
- [x] `mix format --check-formatted` and `mix credo` clean

**Traces to:** [REQ-001], [DESIGN-001]
**Depends on:** [TASK-001]
**Blocks:** [TASK-003], [TASK-004]

### TASK-003: RulesPolicy with deterministic routing
🔴 P0 | ✅ DONE | Est: 0.5d

**Description:**
`Router.Policy` behaviour + `RulesPolicy` v1 returning a `Decision` from
explicit rules, per DESIGN-002.

**Checklist:**
- [x] `Kapelle.Router.Policy` behaviour (`route/2` callback)
- [x] `Kapelle.Router.RulesPolicy`: explicit rules → deterministic target; `decision_id` unique per call (Ecto.UUID)
- [x] Table-driven tests: same task → same target; decision_id differs; unknown task shape → {:error, _}
- [x] format + credo clean

**Traces to:** [REQ-002], [DESIGN-002]
**Depends on:** [TASK-002]
**Blocks:** [TASK-004]

### TASK-004: Fake executor + fake judge, synchronous e2e
🔴 P0 | 🔄 IN_PROGRESS | Est: 0.5d

**Description:**
`Executor.Adapter` and `Evaluator.Judge` behaviours with fake implementations;
one synchronous pipeline function proving submit → verdict without network,
per DESIGN-003/004.

**Checklist:**
- [ ] `Kapelle.Executor.Adapter` behaviour + `FakeAdapter` (configurable canned Result)
- [ ] `Kapelle.Evaluator.Judge` behaviour + `FakeJudge` (score from Result.status, non-empty score_components)
- [ ] `Kapelle.Orchestrator.Pipeline.run_sync/2`: route → execute → evaluate, returns {:ok, Verdict}
- [ ] e2e test: submitted task yields Verdict referencing the originating decision_id; zero network
- [ ] format + credo clean

**Traces to:** [REQ-003], [DESIGN-003], [DESIGN-004]
**Depends on:** [TASK-002], [TASK-003]
**Blocks:** [TASK-005]

### TASK-005: Persist run/task/decision/verdict in Postgres
🔴 P0 | ⬜ TODO | Est: 1d

**Description:**
Ecto schemas + migration for runs, run_tasks, decisions, verdicts; pipeline
persists each step, per DESIGN-005. Verdict→decision FK NOT NULL (NFR-003).

**Checklist:**
- [ ] Migration: runs, run_tasks, decisions, verdicts with FKs; verdict.decision_id NOT NULL
- [ ] Ecto schemas + mapping functions from/to contract structs
- [ ] Pipeline persists decision, result summary, verdict per step
- [ ] Integration test (Ecto sandbox): after e2e run all rows exist and are linked by ids
- [ ] format + credo clean

**Traces to:** [REQ-004], [DESIGN-005]
**Depends on:** [TASK-004]
**Blocks:** [TASK-006]

### TASK-006: Move pipeline into Oban
🔴 P0 | ⬜ TODO | Est: 1d

**Description:**
RouteWorker → ExecuteWorker → EvaluateWorker across the configured queues; args
carry ids only, state reloaded from DB, per DESIGN-006.

**Checklist:**
- [ ] Three Oban workers, each enqueues the next; queues orchestrator/executor/evaluator
- [ ] `Pipeline.submit/2` enqueues RouteWorker and returns run id immediately
- [ ] Async integration test via Oban.Testing (testing: :manual): drain queues → verdict persisted
- [ ] Worker failure is retried by Oban policy (test one retry path)
- [ ] format + credo clean

**Traces to:** [REQ-005], [DESIGN-006]
**Depends on:** [TASK-005]
**Blocks:** [TASK-007]

### TASK-007: First real provider adapter
🟠 P1 | ⬜ TODO | Est: 1d

**Description:**
`Providers.ModelFactory` + `ChainAdapter` (langchain ChatAnthropic) behind the
same `Executor.Adapter` behaviour; opt-in smoke test, per DESIGN-007. Default
test suite stays network-free (NFR-002).

**Checklist:**
- [ ] `Kapelle.Providers.ModelFactory.build/1` ("anthropic@model" → %ChatAnthropic{})
- [ ] `Kapelle.Executor.ChainAdapter` for single-prompt tasks returning Result
- [ ] Smoke test `@tag :provider_smoke`, excluded by default in test_helper.exs; reads ANTHROPIC_API_KEY from env
- [ ] Default `mix test` passes with no network and no key present
- [ ] format + credo clean

**Traces to:** [REQ-006], [DESIGN-007], NFR-002
**Depends on:** [TASK-006]
**Blocks:** —

## Dependency Graph

```
TASK-001 ✅
   └─► TASK-002 ──► TASK-003 ──► TASK-004 ──► TASK-005 ──► TASK-006 ──► TASK-007
              └───────────────────►┘
```

## Summary

| Milestone | Tasks | Ready now |
|---|---|---|
| M1 Vertical Slice | TASK-002..TASK-007 (6 open, 1 done manual) | TASK-002 |
