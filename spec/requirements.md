# Kapelle — Requirements (Phase 1: M1 Vertical Slice)

> Product plan: `docs/plans/2026-08-04-bootstrap-plan.md`. This spec covers only
> milestone M1 — the vertical slice — as executable backlog TASK-002..TASK-007
> (aliases KAP-002..KAP-007 in the battle-testing pilot).

## Context

Kapelle is an Elixir/Phoenix orchestrator for LLM agents: a task goes through
Router (model/agent choice) → Executor (LLM or CLI agent) → Evaluator (verdict),
with state in PostgreSQL and async execution via Oban. Independent product; the
Python ecosystem (maestro/arbiter/spec-runner/ATP) is a pattern source only.

**Goal of M1:** one task travels the full pipeline end-to-end with deterministic
fakes, persisted state, and a recorded decision→verdict loop. Real LLM calls are
opt-in and appear only at the very end (TASK-007).

## Out of Scope (Phase 1)

- DAG with dependencies and parallel branches (M4)
- CLI agent adapter via Port/worktrees (M5)
- LiveView dashboard beyond generated skeleton (M3)
- Multi-node distribution, libcluster (M6)
- Learned/statistical routing (M7+); governance gates (never while solo)

## Functional Requirements

#### REQ-001: Contract structs
**As a** developer of any kapelle context
**I want** `Decision`, `Result`, `Verdict` as typed structs with validating constructors
**So that** contexts communicate only through explicit contracts

**Acceptance Criteria:**
```gherkin
GIVEN valid attributes for Decision/Result/Verdict
WHEN new!/1 is called
THEN a struct with enforced keys is returned

GIVEN an invalid status or missing key
WHEN new!/1 is called
THEN an error is raised (no silent defaults)
```

**Priority:** P0
**Traces to:** [TASK-002], [DESIGN-001]

#### REQ-002: Deterministic rules routing
**As an** orchestrator
**I want** `Router.RulesPolicy` returning a `Decision` with a `decision_id` from explicit rules
**So that** routing is predictable and every decision is traceable from day one

**Acceptance Criteria:**
```gherkin
GIVEN a task with known attributes
WHEN RulesPolicy.route/2 is called
THEN the same Decision fields are returned on every call
AND decision_id is unique per call
```

**Priority:** P0
**Traces to:** [TASK-003], [DESIGN-002]

#### REQ-003: End-to-end run on fakes
**As a** developer
**I want** submit → route → execute (fake) → evaluate (fake) → verdict, synchronously, no network
**So that** the pipeline contract is proven before any external dependency

**Acceptance Criteria:**
```gherkin
GIVEN a submitted task
WHEN the pipeline runs with FakeAdapter and FakeJudge
THEN a Verdict referencing the originating decision_id is produced
AND no network calls are made
```

**Priority:** P0
**Traces to:** [TASK-004], [DESIGN-003], [DESIGN-004]

#### REQ-004: Persistence
**As an** operator
**I want** run/task/decision/verdict rows in PostgreSQL
**So that** state survives restarts and the decision→outcome loop is queryable

**Acceptance Criteria:**
```gherkin
GIVEN a completed e2e run
WHEN I query the database
THEN run, task, decision and verdict rows exist and are linked by ids
```

**Priority:** P0
**Traces to:** [TASK-005], [DESIGN-005]

#### REQ-005: Async execution via Oban
**As an** orchestrator
**I want** pipeline steps executed as Oban jobs in queues orchestrator/executor/evaluator
**So that** execution is durable, retryable and observable

**Acceptance Criteria:**
```gherkin
GIVEN a submitted task
WHEN the Oban pipeline processes it
THEN the verdict is persisted asynchronously
AND job failures are retried by Oban policy
```

**Priority:** P0
**Traces to:** [TASK-006], [DESIGN-006]

#### REQ-006: First real provider adapter
**As a** user
**I want** one real LLM provider behind the same `Executor.Adapter` behaviour
**So that** the fake-proven pipeline runs against a real model

**Acceptance Criteria:**
```gherkin
GIVEN ANTHROPIC_API_KEY is set and the opt-in smoke tag is enabled
WHEN the provider smoke test runs
THEN a real completion flows through the pipeline to a Verdict

GIVEN no API key
WHEN the default test suite runs
THEN it passes with zero network calls
```

**Priority:** P1
**Traces to:** [TASK-007], [DESIGN-007]

#### REQ-007: Providers catalog
**As an** operator
**I want** available models declared in `priv/catalog/models.toml` and loaded by a catalog module
**So that** adding or switching a model is a config change, not a code change

**Acceptance Criteria:**
```gherkin
GIVEN a models.toml with provider entries
WHEN Catalog.get("anthropic@<model>") is called
THEN {:ok, entry} with provider, model and params is returned

GIVEN an unknown id or a malformed models.toml
WHEN the catalog is queried or loaded
THEN a clear error is returned (no silent empty catalog)
```

**Priority:** P1
**Traces to:** [TASK-008], [DESIGN-008]

## Non-Functional Requirements

#### NFR-001: Quality gate
`mix test`, `mix format --check-formatted`, `mix credo` green on every task.
**Traces to:** all tasks

#### NFR-002: Network-free default test suite
Provider calls only under an explicit opt-in tag (`@tag :provider_smoke`,
excluded by default).
**Traces to:** [TASK-007]

#### NFR-003: Closed decision loop
Every `Decision` is persisted with `decision_id`; every `Verdict` references it.
No verdict without a traceable decision (bootstrap plan risk R-5).
**Traces to:** [TASK-002], [TASK-005]

## Constraints / Tech Stack

- **Language profile: Elixir** (skill has no built-in profile — conventions fixed
  here): Elixir 1.19.4 / OTP 28.2 (`.tool-versions`), Phoenix 1.8, Ecto/PostgreSQL,
  Oban ~> 2.19, langchain ~> 0.9 (pinned 0.9.6)
- Tests: ExUnit (`mix test`); lint: `mix format --check-formatted && mix credo`
- Contexts communicate only via public functions and contract structs
  (bootstrap plan §3); daisyUI: baseline stays, no new daisyUI components (AGENTS.md)

## Acceptance by Milestone

| Milestone | Exit criterion |
|---|---|
| M1 (this spec) | e2e test: submit → verdict through Oban on fakes (REQ-003..005); provider smoke opt-in green when key present (REQ-006) |
