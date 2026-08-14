# Kapelle.Product S3 — Workers & Minimal E2E Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Native ResearchWorker/CreatorWorker/Evaluator over Oban drive one loop from `Loop.start/2` to `ready_for_business` on deterministic fixture agents, on top of the revision-snapshot store the owner specified on 2026-08-14 — with crash/retry never duplicating artifacts or events, and the outcome matching the golden oracle.

**Architecture:** The store gains a fourth PK member `revision` so evolving documents (product-proposal by `doc["version"]`, exchange-log by `length(entries)`) live as immutable version snapshots; loop-state leaves the authoritative store entirely for a derived projection table that also carries loop config. The view validates whole chains fail-closed (contiguity, frozen identity/refs, FSM progression, byte-canonical prefix property) before selecting latest. Workers are thin Oban shells around the pure core: build view → compute next stage → check own-output idempotency → call the agent port → validate → persist snapshot (authoritative commit, guarded against ambient transactions) → projection → post-commit event → enqueue next stage under the uniqueness key `(loop_id, iteration, stage, input_hash)`. The reconciler re-derives everything from artifacts and repairs projections/jobs. The e2e happy path is judged by the golden oracle, now down to snapshot sequences.

**Tech Stack:** existing Elixir/Ecto/Oban (new queue `product`), Phoenix.PubSub; no new deps.

**Spec:** `docs/superpowers/specs/2026-08-14-product-context-design.md` (§3–§8) **plus the owner's revision-snapshot decision of 2026-08-14** (restated verbatim-in-intent under Global Constraints) **plus the S2 ledger carry-forwards** (N1, N2, transaction guard).

## Global Constraints

- Store PK is `(loop_id, kind, identity, revision)`. Revision: product_proposal → `doc["version"]`, exchange_log → `length(doc["entries"])`, the other four stored kinds → `0`. Semantics: same key + same canonical hash → no-op; same key + different hash → typed conflict; a new admissible revision → a new immutable row; a late lower revision never changes latest; a revision gap or fork makes the View invalid — never a blind `max()`.
- loop-state is NOT stored in the authoritative store: it is a derived projection surface (its own table), excluded from the canonical view and from next-stage. It has no monotonic version of its own; inventing a DB revision for it would mix projection with state.
- Proposal chain (View-validated, fail-closed): starts at the contract-valid initial version; revisions contiguous; `proposal_id`/`idea_ref` frozen across the chain; status changes follow the reference FSM (`draft → in_iteration`, `in_iteration → in_iteration`, `in_iteration → ready`); `iteration` non-decreasing; a terminal version is never superseded by a later revision.
- ExchangeLog chain: revision equals entries count; every earlier snapshot's entries are a byte-canonical immutable prefix of every later one (compare via `CanonicalHash.hash/1` of the entry-list prefix); same revision with different content is a conflict; the `(iteration, stage)` order of entries is valid (non-decreasing iterations; researcher before creator within an iteration).
- `Product.Event` gains `artifact_revision` — `ref + hash` cannot address a specific snapshot.
- Transaction guard: `Store.put/2` (and the projection writers that follow it) must refuse to run inside an ambient DB transaction (`Repo.in_transaction?()` → typed error) — a nested "commit" is not a commit, and events must never precede the real one. Oban's Basic engine executes `perform/1` outside any transaction; the guard makes that assumption enforced instead of trusted. (Outbox is the S4+ path if composition is ever needed; prohibition is the honest S3 floor.) EXCEPTION: the Ecto SQL sandbox wraps every test in a transaction — the guard must treat the sandbox as non-ambient (check `Repo.get_dynamic_repo() != Kapelle.Repo or` — no: use `Application.get_env(:kapelle, :sandbox?)` set in `config/test.exs`; explicit, documented, test-only bypass).
- Workers: Oban queue `product`; uniqueness key `(loop_id, iteration, stage, input_hash)` via Oban `unique` on args; a worker first checks whether its valid output already exists (idempotent re-run); agent failures are typed (`:infrastructure` → Oban retry, `:domain`/`:invalid_artifact` → loop failure, fail-closed).
- Durable boundary order, always: validate → persist immutable snapshot (authoritative) → update projection → publish event → enqueue next-stage job. Nothing observable before the authoritative write.
- S2 data migration: existing product_artifacts rows get computed revisions (proposal → `doc->>'version'`, exchange_log → entries length, others → 0); loop_state rows leave the table.
- Golden parity now checks the snapshot sequence (proposal transitions from the trace vs our chain), not only final documents; the S2 invariant is restated as "same logical identity + same revision + different hash → conflict".
- Everything from S1/S2 keeps passing; `mix format` clean; `mix credo` exit 0 and `--strict` baseline (4 pre-existing); no network in tests; nothing under `lib/kapelle/orchestrator/`; PR review human + Copilot; the tool never touches `master`.

---

### Task 1: Revision snapshots in the store

**Files:**
- Create: `priv/repo/migrations/<ts>_add_revision_to_product_artifacts.exs`
- Modify: `lib/kapelle/product/records/artifact_row.ex`, `lib/kapelle/product/store.ex`, `lib/kapelle/product/event.ex`
- Test: modify `test/kapelle/product/store_test.exs`

**Interfaces:**
- Produces: `Store.put(Record.t(), loop_id)` unchanged signature; revision computed internally via `Store.revision_of(kind, doc)` (public, `:product_proposal → doc["version"]`, `:exchange_log → length(doc["entries"])`, else `0`); rows carry `revision`; `Store.all/1` rows gain `revision :: integer`; `%Event{artifact_revision: integer}`.

- [ ] **Step 1: Failing tests** — extend store_test with:

```elixir
  test "a new admissible revision of the proposal is a new immutable row, event carries the revision" do
    v1 = proposal_record(version: 1)
    v2 = proposal_record(version: 2)
    :ok = Events.subscribe("LOOP-R1")
    assert {:ok, :inserted} = Store.put(v1, "LOOP-R1")
    assert_receive %Event{artifact_revision: 1}
    assert {:ok, :inserted} = Store.put(v2, "LOOP-R1")
    assert_receive %Event{artifact_revision: 2}
    assert [%{revision: 1}, %{revision: 2}] =
             Store.all("LOOP-R1") |> Enum.filter(&(&1.kind == :product_proposal)) |> Enum.sort_by(& &1.revision)
  end

  test "same revision with different content is a conflict; a re-put of the same bytes is a no-op" do
    v2 = proposal_record(version: 2)
    assert {:ok, :inserted} = Store.put(v2, "LOOP-R2")
    assert {:ok, :noop} = Store.put(v2, "LOOP-R2")
    mutated = %{v2 | doc: put_in(v2.doc["content"], %{"delta_log" => ["x"]})}
    assert {:error, {:artifact_conflict, :product_proposal, _, _, _}} = Store.put(mutated, "LOOP-R2")
  end
```

with a `proposal_record/1` helper building a schema-valid proposal doc through `Loader` from a template map (base it on the vendored valid fixture, overriding `version`; construct YAML via a small sigil/heredoc — never insert unvalidated docs).

- [ ] **Step 2: Migration** — `alter table(:product_artifacts)`: since Postgres can't alter a PK in place trivially, do it explicitly: `drop constraint product_artifacts_pkey`, `add :revision, :integer, null: false, default: 0`, backfill (`execute` UPDATE: proposal rows `set revision = (doc->>'version')::int`, exchange_log rows `set revision = jsonb_array_length(doc->'entries')`), `execute "DELETE FROM product_artifacts WHERE kind = 'loop_state'"` (they move to the projection surface in Task 3; the only existing data is test-seeded), then `execute` re-create the PK over `(loop_id, kind, identity, revision)`. Down: reverse.
- [ ] **Step 3: Implement** — `revision_of/2`; `Store.put` computes revision, `get_by` includes it; conflict tuple unchanged in shape; `Event` struct + broadcast gains `artifact_revision: revision`; the S2 exit-gate tests updated where they asserted the 3-part key. Run the two new tests + full suite.
- [ ] **Step 4: Commit** — `git add -A && git commit -m "feat(store): immutable revision snapshots — PK (loop_id, kind, identity, revision), events carry the revision"`

### Task 2: The transaction guard

**Files:**
- Modify: `lib/kapelle/product/store.ex`, `config/test.exs`
- Test: `test/kapelle/product/store_guard_test.exs`

**Interfaces:**
- Produces: `Store.put/2` returns `{:error, :ambient_transaction}` when called inside a caller-held transaction (outside the sandbox bypass).

- [ ] **Step 1: Failing test**

```elixir
defmodule Kapelle.Product.StoreGuardTest do
  use Kapelle.DataCase, async: true

  alias Kapelle.Product.Store

  test "put/2 refuses inside an ambient transaction" do
    record = ... # any valid record via Loader from a vendored fixture

    Application.put_env(:kapelle, :sandbox?, false)
    on_exit(fn -> Application.put_env(:kapelle, :sandbox?, true) end)

    {:ok, result} = Repo.transaction(fn -> Store.put(record, "LOOP-G1") end)
    assert result == {:error, :ambient_transaction}
  end
end
```

- [ ] **Step 2: Implement** — at the top of `Store.put/2`:

```elixir
    if Repo.in_transaction?() and not sandbox?() do
      {:error, :ambient_transaction}
    else
      ...existing body...
    end

  defp sandbox?, do: Application.get_env(:kapelle, :sandbox?, false)
```

`config/test.exs`: `config :kapelle, sandbox?: true`. Document in the moduledoc: the authoritative write IS the commit; a nested return is not a commit and the post-insert event must never precede the real one; outbox is the composition path if a future slice needs it.

- [ ] **Step 3: Run, full suite, commit** — `git commit -m "feat(store): ambient-transaction guard — the write is the commit, or it refuses"`

### Task 3: loop-state leaves the store; loop config + projection table

**Files:**
- Create: `priv/repo/migrations/<ts>_create_product_loops.exs`, `lib/kapelle/product/records/loop_row.ex`, `lib/kapelle/product/loops.ex`
- Modify: `lib/kapelle/product/view.ex` (drop `loop_state` field and its lenient path — `gate_decision` stays lenient), `test/kapelle/product/view_test.exs`, `test/kapelle/product/parity_happy_test.exs`
- Test: `test/kapelle/product/loops_test.exs`

**Interfaces:**
- Produces: table `product_loops` (`loop_id` PK string, `idea_identity`, `proposal_id`, `exchange_log_id`, `max_iterations`, `agent :: string`, `status :: string` ("running" | "ready" | "needs_human" | "failed"), `stop_reason :: string | nil`, `latest_state :: map | nil` — the producer-format loop-state document as a pure projection, timestamps). `Kapelle.Product.Loops`: `create/1`, `get!/1`, `set_status/3` (monotonic terminal via the Terminal pattern — write your own conditional UPDATE, do NOT import the orchestrator's), `put_state_projection/2` (overwrites `latest_state`; deletable/reconstructible by definition). `View` no longer has `loop_state`; `Loader`/`Validator` still validate the `:loop_state` kind (the schema stays vendored; parity still validates the golden file's shape before projecting it).

- [ ] Steps: failing tests (create/get, monotonic terminal status: `set_status(loop, "ready", reason)` then `set_status(loop, "failed", _)` → `{:error, :already_terminal}` and status stays "ready"; projection overwrite is idempotent) → migration + implement → rework `View` (remove `loop_state`; `dropped` diagnostics stay for `gate_decision` only) → parity test: golden `loop.state` file now `Loader.load(:loop_state, ...)`-validated and stored via `Loops.put_state_projection/2` with `max_iterations` read from the validated doc into `Loops.create/1`; `view.loop_state` references replaced. Full suite. Commit `feat(product): loop config + projection surface; loop-state leaves the authoritative store`.

### Task 4: Chain validation in the view + parity upgraded to snapshot sequences

**Files:**
- Modify: `lib/kapelle/product/view.ex`, `lib/kapelle/product/oracle/normalizer.ex` (only if needed for transition observations — it already emits `proposal_transition`), `test/kapelle/product/view_test.exs`, `test/kapelle/product/parity_happy_test.exs`

**Interfaces:**
- Produces: `View.build/1` validates full chains and exposes `proposal :: map()` (the latest valid snapshot), `proposal_chain :: [map()]` (ascending revisions), `exchange_log`/`exchange_log_chain` likewise. New typed errors: `{:revision_gap, %{kind, identity, missing}}`, `{:revision_fork, %{kind, identity, revision}}` (fork = impossible under the PK, but a defense-in-depth check over `Store.all` costs three lines — keep it), `{:chain_violation, %{kind, rule, detail}}` for: initial-version invalid, identity/idea_ref drift, FSM regression (`ready → in_iteration` etc.), iteration decrease, terminal superseded, exchange-log prefix broken, exchange-log entry order invalid.

- [ ] Steps: failing tests for each chain rule (build v1..v3 proposal snapshots via a template helper, then: gap (v1, v3), idea_ref drift at v2, status regression ready→in_iteration, terminal-then-v4, exchange-log rewritten history (same-length prefix mismatch), entry order violation) → implement `check_proposal_chain/1` + `check_exchange_chain/1` inside the group/validate pipeline → carry the two S2 parked items here: **N1** (parity's oracle-observation loop asserts `length(observations) == 4` before iterating) and **N2** (the four remaining reference edges: `concept_draft.idea_ref`, `research_pack.proposal_ref`, `concept_draft.proposal_ref`, `exchange_log.proposal_ref` — same `{:reference_mismatch, ...}` shape) → parity: assert our proposal chain's `(from_status, to_status, version)` sequence equals the golden trace's `transition` observations (normalizer already yields them; wire the comparison) → full suite → commit `feat(view): fail-closed chain validation; parity compares snapshot sequences against the oracle`.

### Task 5: The agent port and the fixture agent

**Files:**
- Create: `lib/kapelle/product/agent.ex`, `test/support/product_fixture_agent.ex`
- Test: `test/kapelle/product/fixture_agent_test.exs`

**Interfaces:**
- Produces:

```elixir
defmodule Kapelle.Product.Agent do
  @moduledoc "Port for loop agents (design §4): fixture-backed in M3, real adapters later."

  @type role :: :researcher | :creator
  @type failure :: {:infrastructure, term()} | {:domain, term()} | {:invalid_artifact, term()}

  @callback produce(role(), iteration :: non_neg_integer(), context :: map()) ::
              {:ok, map()} | {:error, failure()}
end
```

`Kapelle.Product.FixtureAgent` (test/support): configured with a script — a map `%{{role, iteration} => doc_map | {:error, failure}}` held in a `:persistent_term` under a test-chosen key passed via loop config `agent: "fixture:<key>"`; resolution helper `Kapelle.Product.Agent.resolve!("fixture:" <> key)`. The happy-path script is loaded from the golden workspace's rp-*/cd-* files (parsed via StrictParse — they are real producer documents), so the e2e drives the exact golden scenario.

- [ ] Steps: failing tests (script produce ok; scripted `{:error, {:infrastructure, :flaky}}` returns typed; missing script entry → `{:error, {:domain, {:no_script, role, iteration}}}`) → implement → commit `feat(product): agent port + fixture agent scripted from the golden workspace`.

### Task 6: Loop.start — the init_loop port

**Files:**
- Create: `lib/kapelle/product/loop.ex`
- Test: `test/kapelle/product/loop_test.exs`

**Interfaces:**
- Produces: `Kapelle.Product.Loop.start(idea_yaml :: binary(), opts)` with `opts`: `loop_id`, `proposal_id`, `exchange_log_id`, `max_iterations (>= 1)`, `agent`. Port of the producer's `init_loop` (verified against the pin; the initial shapes below are the producer's, byte-faithful in intent):
  1. `Loader.load(:idea, idea_yaml)` — invalid idea → typed error, nothing persisted.
  2. `Loops.create/1` refuses an existing loop_id (`{:error, :already_initialized}`).
  3. Persist the idea record via `Store.put/2`.
  4. Persist the initial proposal snapshot (revision 1), built exactly as the producer does:

```elixir
%{
  "proposal_id" => proposal_id,
  "idea_ref" => "idea://" <> idea.id,
  "version" => 1,
  "status" => "draft",
  "iteration" => 0,
  "refs" => %{"exchange_log" => "exchange-log://" <> exchange_log_id},
  "content" => %{"delta_log" => []},
  "created_at" => now_iso,
  "updated_at" => now_iso
}
```

  (validated through `Validator` before `Store.put` — if the vendored schema rejects this shape, STOP: the port drifted, report the errors verbatim.)
  5. Persist the initial exchange-log snapshot (revision 0): `%{"id" => exchange_log_id, "proposal_ref" => "proposal://" <> proposal_id, "entries" => []}` (same STOP condition).
  6. Write the loop-state projection (producer shape: loop_id, idea_ref, `idea_input_hash: CanonicalHash.hash(idea.doc)`, proposal_id, exchange_log_id, max_iterations, stop: nil) via `Loops.put_state_projection/2`.
  7. Enqueue the first stage job (`{:research, 0}`) — Task 7's worker; insert via the shared enqueue helper with the uniqueness key.
  `now_iso` comes in `opts` (default `DateTime.utc_now/0` at the CALLER, tests pass a fixed one — determinism).

- [ ] Steps: failing tests (successful start persists idea + proposal v1 + log rev0 + projection + enqueues exactly one `:research/0` job [use Oban.Testing `assert_enqueued`]; double start → `:already_initialized`; invalid idea → typed, zero rows) → implement → commit `feat(product): Loop.start — the init_loop port, artifacts first, one job enqueued`.

### Task 7: The three workers and the shared stage shell

**Files:**
- Create: `lib/kapelle/product/workers/stage_shell.ex`, `lib/kapelle/product/workers/research_worker.ex`, `lib/kapelle/product/workers/creator_worker.ex`, `lib/kapelle/product/workers/evaluate_worker.ex`
- Modify: `config/config.exs` (queues: add `product: 5`)
- Test: `test/kapelle/product/workers/research_worker_test.exs` (+ per-worker files)

**Interfaces:**
- Produces: each worker is `use Oban.Worker, queue: :product, unique: [fields: [:worker, :args], keys: [:loop_id, :iteration, :stage, :input_hash]]` with args `%{"loop_id", "iteration", "stage", "input_hash"}`. `StageShell.run(job_args, stage_impl)` implements the invariant shell:
  1. `Loops.get!` (terminal loop → `:ok` discard, log).
  2. `View.build(loop_id)` — fail-closed error → `Loops.set_status(loop, "failed", inspect(reason))` + `{:cancel, reason}`.
  3. `NextStage.compute(view, max)` — if it names a DIFFERENT stage/iteration than the job's, the job is stale: `:ok` no-op (the reconciler or a competing worker already advanced; log).
  4. Idempotency: if the stage's output artifact already exists in the view (research_pack[i] for `:research`, etc.), skip to the enqueue step.
  5. Stage work (the `stage_impl` closure) — produce+validate+`Store.put` the output; agent `{:error, {:infrastructure, r}}` → `{:error, r}` (Oban retries); `{:domain, r}`/`{:invalid_artifact, r}` → `Loops.set_status(..., "failed", ...)` + `{:cancel, r}`.
  6. Projection update (`Loops.put_state_projection/2` — producer-shape doc rebuilt from the view; stop set on terminal).
  7. (Event was already emitted by `Store.put`.)
  8. Enqueue the next stage per a fresh `NextStage.compute` (or set terminal status on `{:terminal, ...}`), under the uniqueness key with `input_hash` = `CanonicalHash.hash/1` of the stage's primary input doc: research → the idea doc; creator → the research pack of its iteration; evaluate/apply → the concept draft of its iteration.
- Stage impls:
  - **research**: agent.produce(:researcher, i, %{view}) → `Loader`-style validate via `Validator.validate(:research_pack, doc)` + `Identity.of` → `Store.put` → append exchange entry (see below).
  - **creator**: same for `:concept_draft`, plus the producer's stale-reference check BEFORE persisting: `doc["based_on_research"]["ref"] == "research-pack://" <> rp.id` else domain failure (fail-closed, like loop.py:580).
  - **evaluate**: no agent. Applies the delta (port of `_apply_delta`'s essentials: proposal v+1 with `iteration: i`, delta_log appended `%{"iteration" => i, "rp" => rp_ref, "cd" => cd_ref}`, `status: "in_iteration"` on first entry — **verify the exact delta shape against the golden proposal_chain: the golden's final proposal doc IS the ground truth for what `_apply_delta` produces; diff your构 output against it and STOP on any field you cannot derive**), then `NextStage.compute` on the fresh view: `{:terminal, :ready, reason}` → persist final proposal snapshot with `status: "ready"` (v+1), set loop status; `{:terminal, :needs_human, reason}` → loop status + projection stop (proposal status untouched — producer semantics); `{:run, {:research, i+1}}` → enqueue.
- Exchange entries: each research/creator stage appends to the exchange log — build the new snapshot (entries + one producer-shaped entry `%{"iteration" => i, "role" => role, "kind" => kind, "ref" => ref}` — **verify the exact entry shape against the golden exchange-log.yaml, STOP on mismatch**) and `Store.put` it (new revision). The prefix property then holds by construction.

- [ ] Steps: TDD per worker over the FixtureAgent happy script (research worker test: performs, persists rp rev0, appends log entry, enqueues creator; creator: stale-ref rejection case + happy; evaluate: delta + continue and delta + ready paths) → wire queue config → full suite → commit per worker or one commit `feat(product): stage workers over the shared shell — validate, persist, project, enqueue`.

### Task 8: Reconciler + crash/retry evidence + the e2e gate

**Files:**
- Create: `lib/kapelle/product/reconciler.ex`
- Test: `test/kapelle/product/reconciler_test.exs`, `test/kapelle/product/e2e_happy_test.exs`

**Interfaces:**
- Produces: `Reconciler.reconcile(loop_id) :: {:ok, :terminal | :repaired | :in_sync} | {:error, view_error}` — re-reads artifacts, computes the stage, repairs the projection (`put_state_projection` + terminal status if the view says so), enqueues the missing job under the uniqueness key. Pure repair: calling it on a healthy loop changes nothing (`:in_sync`).

- [ ] **Reconciler tests**: (a) delete the projection row's `latest_state`, reconcile → repaired byte-identically to what the artifacts imply; (b) simulate crash-after-authoritative-commit: persist rp(0) manually via the worker's own store path but DON'T enqueue creator — reconcile enqueues exactly the creator job (assert_enqueued with the exact uniqueness args), and a SECOND reconcile is `:in_sync` with no duplicate job (Oban uniqueness proves itself); (c) terminal loop → `:terminal`, nothing enqueued.
- [ ] **E2E happy** (the S3 exit gate), `async: false`, `Oban.Testing` inline or `use Oban.Testing, repo:` + `Oban.drain_queue(queue: :product, with_recursion: true)`:

```elixir
  test "Loop.start + drained product queue reaches ready_for_business and matches the golden oracle" do
    script = FixtureAgent.script_from_golden!()   # rp/cd docs from the golden workspace
    {:ok, _} = Loop.start(File.read!(golden("workspace/idea.yaml")),
      loop_id: "LOOP-101", proposal_id: "PP-101", exchange_log_id: "XL-101",
      max_iterations: 2, agent: script, now_iso: "2026-08-01T00:00:00Z")

    Oban.drain_queue(queue: :product, with_recursion: true)

    loop = Loops.get!("LOOP-101")
    assert loop.status == "ready"

    {:ok, view} = View.build("LOOP-101")
    # The oracle comparison, snapshot-sequence deep:
    # 1. every golden artifact_written observation has a matching store row
    #    (kind, identity, revision where applicable) with EQUAL canonical hash;
    # 2. our proposal chain's (from, to, version) transitions equal the golden
    #    trace's transition observations;
    # 3. final proposal doc equals the golden workspace's proposal.yaml by
    #    canonical hash. STOP if 3 fails on `created_at/updated_at`-class
    #    fields only — report the exact field diff; timestamps are the one
    #    sanctioned divergence candidate and the resolution (fixed now_iso
    #    threading) is the controller's call, not a weakened assertion.
  end
```

- [ ] **Crash/retry no-dup**: re-run a completed stage job by inserting the same args manually and performing — assert `:ok`, zero new artifacts (Store row count unchanged), zero new events (subscribe + refute_receive), zero extra jobs.
- [ ] Full suite; format; credo. Commit `feat(product): reconciler + e2e happy path judged by the golden oracle`.

### Task 9: Docs stitch and the PR

- [ ] Design doc `Status:` line += `S3 implementation: docs/superpowers/plans/2026-08-14-product-s3-workers-e2e.md.`
- [ ] Full verification; commit; push; `gh pr create` — body: what shipped (revision snapshots + owner's amendments, loop-state projection split, chain validation, workers/reconciler/e2e vs oracle), the S2 carry-forwards resolved here (N1, N2, transaction guard), carry-forwards remaining for S4 (human_waiver parity case, PROVENANCE self-integrity N4-N6, needs_human resume blocked on impresario#14), and the note that **the contour unlocks after this merge** per the hybrid decision.
- [ ] Handle Copilot; human merges.

## Self-Review

- **Owner's revision decision coverage**: PK+semantics (T1), loop-state projection split (T3), chain rules verbatim-in-intent (T4), Event.artifact_revision (T1), S2 migration/backfill incl. loop_state eviction (T1+T3), parity to snapshot sequences (T4+T8), restated invariant (T1 tests), transaction guard with sandbox carve-out and outbox note (T2).
- **Spec §8-S3 exit gates**: Oban happy path to ready (T8 e2e), crash/retry no duplication (T8, Oban uniqueness + idempotency checks at T7 shell), outcome matches golden oracle (T8, three-level comparison).
- **Named risks with STOP conditions**: initial proposal/exchange-log shapes vs vendored schemas (T6), delta/entry exact shapes vs golden ground truth (T7), timestamp-class divergence in final-hash equality (T8). The producer's code is never read at runtime; ports are judged by schemas + golden.
- **Type consistency**: `Store.revision_of/2` used by T1 tests and T4 chain checks; `Loops` API shared by T3/T6/T7/T8; `Agent.resolve!/1` naming consistent between T5 and T6/T7; uniqueness args identical in T6 enqueue, T7 workers, T8 reconciler assertions.
- **Scope check**: this is one coherent slice (the store amendment is the workers' load-bearing floor; splitting would leave S3a unshippable alone since S2 tests must be rewritten twice). Fault-injection matrix and LiveView stay S4 per the design.
