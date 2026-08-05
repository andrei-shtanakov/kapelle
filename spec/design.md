# Kapelle — Design (Phase 1: M1 Vertical Slice)

> Architecture source: `docs/plans/2026-08-04-bootstrap-plan.md` §1–§3 (contexts
> mapping, stack, directory layout). This document specifies only what M1 builds.

## Principles

- One Phoenix app, bounded contexts: `Orchestrator`, `Router`, `Executor`,
  `Evaluator`, `Providers` (+ `KapelleWeb`). Contexts talk only through public
  functions and the contract structs below.
- Behaviours at every pluggable seam (policy, adapter, judge) — fakes and real
  implementations are equal citizens.
- The decision→verdict loop is recorded from the first line of code (R-5).

## High-Level Flow (M1)

```
submit(task)
   │
   ▼
Router.Policy.route/2 ──► %Decision{decision_id}
   │
   ▼
Executor.Adapter.execute/2 ──► %Result{status: :pass|:fail|:error}
   │
   ▼
Evaluator.Judge.evaluate/2 ──► %Verdict{decision_id, total_score, components}
   │
   ▼
PostgreSQL (runs, tasks, decisions, verdicts)      [Oban queues from TASK-006]
```

## Components

### DESIGN-001: Contract structs

`lib/kapelle/router/decision.ex`, `lib/kapelle/executor/result.ex`,
`lib/kapelle/evaluator/verdict.ex`. Plain structs (not Ecto schemas — persistence
arrives in TASK-005 as separate schemas mapped from these structs).

```elixir
defmodule Kapelle.Router.Decision do
  @enforce_keys [:decision_id, :task_id, :target, :decided_at]
  defstruct [:decision_id, :task_id, :target, :decided_at, features: %{}]
  # target: %{provider: String.t(), model: String.t()}
  @spec new!(map()) :: t()  # raises on missing keys / bad types
end

defmodule Kapelle.Executor.Result do
  @enforce_keys [:task_id, :status]
  defstruct [:task_id, :status, :output, :duration_ms, artifacts: []]
  # status: :pass | :fail | :error  (mirrors spec-runner exit 0/1/2)
end

defmodule Kapelle.Evaluator.Verdict do
  @enforce_keys [:decision_id, :task_id, :total_score]
  defstruct [:decision_id, :task_id, :total_score, score_components: %{}]
  # score_components must never be dropped (ATP `total_score`-only gap lesson)
end
```

Each struct: `@type t`, `new!/1` with validation, unit tests incl. invalid input.
**Traces to:** [REQ-001], [REQ-006 NFR-003]

### DESIGN-002: Router behaviour + rules policy

```elixir
defmodule Kapelle.Router.Policy do
  @callback route(task :: map(), opts :: keyword()) ::
              {:ok, Kapelle.Router.Decision.t()} | {:error, term()}
end
```

`RulesPolicy` (v1): explicit pattern-matched rules, deterministic target,
`decision_id = Ecto.UUID.generate()`. Table-driven tests.
**Traces to:** [REQ-002]

### DESIGN-003: Executor behaviour + fake adapter

```elixir
defmodule Kapelle.Executor.Adapter do
  @callback execute(task :: map(), decision :: Decision.t()) ::
              {:ok, Result.t()} | {:error, term()}
end
```

`FakeAdapter` (test double, lives in `lib/` — used by dev seeds too): returns a
canned `Result`, configurable outcome. Real `ChainAdapter` is out of M1 scope
except the provider smoke in TASK-007.
**Traces to:** [REQ-003]

### DESIGN-004: Evaluator behaviour + fake judge

```elixir
defmodule Kapelle.Evaluator.Judge do
  @callback evaluate(task :: map(), result :: Result.t()) ::
              {:ok, Verdict.t()} | {:error, term()}
end
```

`FakeJudge`: deterministic score from `Result.status`, non-empty
`score_components`.
**Traces to:** [REQ-003]

### DESIGN-005: Persistence

Ecto schemas + migration: `runs`, `run_tasks`, `decisions`, `verdicts`
(decision_id/task_id FKs; verdict → decision link NOT NULL — enforces NFR-003).
Context functions persist each pipeline step; integration test asserts linked
rows after an e2e run.
**Traces to:** [REQ-004]

### DESIGN-006: Oban pipeline

Queues (already configured): `orchestrator: 5, executor: 10, evaluator: 5`.
Workers `RouteWorker` → `ExecuteWorker` → `EvaluateWorker`, each step enqueues
the next; args carry ids only (reload state from DB). Test with
`Oban.Testing`/`testing: :manual`.
**Traces to:** [REQ-005]

### DESIGN-007: Provider adapter (minimal)

`Providers.ModelFactory.build("anthropic@<model>")` → `%ChatAnthropic{}`
(langchain). `ChainAdapter` implementing `Executor.Adapter` for single-prompt
tasks only. Smoke test `@tag :provider_smoke`, excluded by default in
`test_helper.exs`.
**Traces to:** [REQ-006], NFR-002

### DESIGN-008: Providers catalog

`priv/catalog/models.toml` — id convention `"<provider>@<model>"` (mirrors the
ecosystem agents-catalog convention), per-entry params (temperature, max_tokens).
`Kapelle.Providers.Catalog`: `load/0` (validated, clear errors on malformed
file), `get/1` by id, `list/0`. Consumed later by `ModelFactory` (DESIGN-007 /
TASK-007). Needs a TOML dep in mix.exs. Independent of the persistence chain —
the S2 parallel branch.
**Traces to:** [REQ-007]

## Key Decisions (from product plan, restated)

- Contracts as structs before persistence (ADR-style: contracts-first) — TASK-002
  blocks everything.
- Fakes prove the pipeline before network (REQ-003 before REQ-006).
- Oban args = ids only; state lives in Postgres (durability over convenience).

## Directory Additions (M1)

```
lib/kapelle/
├── orchestrator/ pipeline.ex  workers/{route,execute,evaluate}_worker.ex
├── router/       policy.ex  rules_policy.ex  decision.ex
├── executor/     adapter.ex  fake_adapter.ex  chain_adapter.ex  result.ex
├── evaluator/    judge.ex  fake_judge.ex  verdict.ex
└── providers/    model_factory.ex
```
