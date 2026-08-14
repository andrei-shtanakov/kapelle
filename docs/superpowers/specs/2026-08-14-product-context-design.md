# Kapelle.Product — airun M3 battle-test design

Status: approved in discussion 2026-08-13/14 (owner: Andrei); this document is
the written record. Scope: airun M3 — Kapelle reproduces the impresario
`forconcept` reference semantics as an execution backend and battle-tests its
own durability doing so (guide §9, exit criteria §9.3).

## 1. Goal and two-axis verdict

One ProductProposal loop (Research → Creator → Evaluator → Verdict) runs on
Kapelle's durable execution (Oban + Postgres) and produces the same domain
transitions as the impresario reference runner on the same fixtures. Every run
is judged on two axes that never collapse into one: **product** (proposal
quality, evidence correctness, gate readiness) and **harness** (durability,
recovery, idempotency, observability, cost, intervention). `product=pass,
harness=observability_gap` is a useful result, not a rounding error.

Exit (M3): Kapelle reproduces reference semantics and passes the durability
criteria of §9.3 — ready-case completes without manual state edits; crash
after every durable boundary resumes without duplicates; late/duplicate
results never overwrite a terminal verdict; one iteration never applies
twice; invalid artifacts stop progress fail-closed; needs-human keeps
inspectable state and a resume path; cost and interventions are visible per
run; reference and Kapelle agree on fixtures.

## 2. Execution mode (hybrid)

- Specification, skeleton, contract vendoring, and the first vertical slices
  (S1–S3) are hand-written PRs with human review.
- From the first minimal e2e path (end of S3), subsequent bounded tasks run
  through spec-runner/Maestro as battle-test workload.
- Fault injection and golden-trace parity runs go through the contour,
  always.
- The contour's review stage is advisory evidence, never the only merge
  gate: human/Copilot review stays mandatory. Task budgets are set with an
  explicit review reserve — and, until spec-runner grows an enforceable
  reserve (spec-runner#267), with enough headroom that earlier stages cannot
  starve the review call.

## 3. Bounded context and ownership

- **Impresario owns** the JSON Schemas and the semantics of ResearchPack,
  ConceptDraft, ProductProposal, ExchangeLog, loop-state, and the related
  verdicts. The ProductProposal FSM is an impresario contract.
- **Kapelle vendors** the schemas at a single producer commit and checks
  copy integrity and upstream drift.
- **`Kapelle.Product`** (new bounded context, `lib/kapelle/product/`) owns
  only the consumer side: parsing, validation, typed records, and the
  translation to/from orchestration messages.
- **`Kapelle.Orchestrator` gets no product fields** in `Run`, `Decision`,
  or the shared `Verdict`.

Invariants (owner-stated, verbatim in intent):

1. Dependency direction: Product → Orchestrator ports; never
   Orchestrator → Product schemas.
2. Generic durable execution knows only job/run/artifact references and
   terminal/retryable outcomes.
3. The product verdict adapts to the shared orchestration outcome through a
   dedicated adapter.
4. An unknown or invalid contract version is a typed product validation
   failure — never a generic success.
5. A pin update is one atomic re-vendor PR with provenance and golden
   compatibility evidence.
6. No runtime references to `../impresario` or `_cowork_output` — ever.

### The event bridge

The bridge carries identity, provenance, and a reference — never the payload:

```elixir
%Kapelle.Product.Event{
  run_id: ...,
  loop_id: ...,
  iteration: ...,
  kind: :research_completed,
  artifact_kind: :research_pack,
  artifact_ref: "research-pack://RP-101",
  artifact_hash: "sha256:...",
  producer: :research_worker
}
```

The contract document itself is an immutable artifact. `Kapelle.Product`
re-validates the document against the vendored schema **before** publishing
the event. The `artifact_hash` doubles as a crash-recovery check: on resume,
re-validating ref+hash catches artifact substitution between iterations
(§9.3 "invalid artifact stops progress fail-closed").

## 4. Workers: native semantics, deterministic agents

- `ResearchWorker`, `CreatorWorker`, and `Evaluator` implement the reference
  semantics **natively in Elixir**. Shelling out to `impresario forconcept`
  is not used even as an interim step: it would be temporary architecture
  proving only process spawning. The single exception is a **test-only
  oracle adapter** that may run the pinned impresario to generate or refresh
  golden evidence — outside Kapelle's runtime. The shipped application,
  release, and runtime config contain no path to and no dependency on the
  impresario binary.
- Agents attach through a behaviour/port. M3 uses fixture-backed
  deterministic implementations; real LLM/provider adapters are a separate
  milestone.
- Agent failures are typed: retryable infrastructure, terminal domain
  failure, invalid artifact.

## 5. State model: artifacts are the state

Authority is the validated set of immutable product artifacts, their hashes,
and the idempotent delta log. The next stage is a **pure function of the
canonical artifact view**. Oban jobs, run/iteration rows, and LiveView state
are derived operational projections: deletable, fully reconstructible, and
updated atomically only **after** the authoritative boundary. A projection
that disagrees with the artifacts is a typed drift/reconciliation outcome,
never a reason to continue from a database row.

`loop-state/v1` exists upstream (impresario `51e3103`) and is handled the
same way: validated, stored, compared as a producer projection / oracle
evidence — but **never consumed by the authoritative next-stage
computation**, which reads only idea / research-pack / concept-draft /
product-proposal / exchange-log / decision artifacts. Anything else would
reintroduce a second source of truth through the back door.

### Canonical artifact view (not "which files exist")

1. Fetch the artifacts of the specific `loop_id`.
2. Validate schema, subject identity, hash, and references.
3. Reject duplicates and ambiguous competing artifacts.
4. Verify the iteration/stage sequence is possible.
5. Only then compute the next stage.

Missing → proceed to the next stage. Invalid, conflicting, hash-mismatched,
or impossible-sequence → fail closed. Otherwise corruption masquerades as a
stage that merely hasn't run yet.

### Durable boundary

```
worker output
  → validate
  → persist immutable artifact idempotently
  → commit authoritative artifact
  → publish/update derived projection
  → enqueue next-stage job
```

A crash after the authoritative commit but before projection/enqueue is
healed by the reconciler/resume: re-read artifacts → compute the stage →
repair the projection → enqueue the missing job under the uniqueness key
`(loop_id, iteration, stage, input_hash)`. Re-delivery or re-execution never
duplicates: a worker first checks whether a valid output for the same
identity/input hash already exists. (The reference runner's delta-log keys
already have exactly this shape — `"LOOP-101:0:researcher"` =
loop:iteration:stage — so this is a transfer, not an invention.)

### Mandatory fault-injection points

1. After artifact persistence, before projection.
2. After projection, before enqueue.
3. After enqueue, before ack.
4. Worker re-run after its artifact is already written.
5. Derived row deliberately stale or contradicting the artifacts.
6. Artifact present but hash/schema/identity corrupted.

## 6. Golden oracle and parity

Parity compares **domain observations**, not trace-line formats. The golden
oracle is a normalized test contract per step:

- iteration
- stage
- artifact kind / ref / hash
- proposal transition
- verdict
- stop reason class

This shields parity from immaterial Elixir/Python differences (JSON key
order, local paths, timestamps, technical trace events).

Golden-set provenance must include: the full impresario commit; fixture and
script identities with hashes; the generation command; the raw reference
trace; the normalized expected trace; the normalizer version. Updating
golden evidence is an explicit, reviewable operation — never an automatic
rewrite on test failure. A useful side effect: on a pin re-vendor, the
regenerated normalized traces diff shows *semantic* protocol changes, not
noise.

## 7. Vendored contract set (one snapshot)

Seven schemas, all at **one full impresario producer commit**: `idea`,
`research-pack`, `concept-draft`, `product-proposal`, `exchange-log`,
`loop-state`, `gate-decision`. Not vendored: `ranked-backlog`,
`axis-assessment` (backlog phase, out of M3), `run-record` (reference-runner
bookkeeping; Kapelle has its own Run projection).

Mechanics: one atomic re-vendor script; separate versioned directories
(`contracts/impresario/<name>/v1/`); copy-integrity test per contract;
**anti-mix invariant — every manifest must carry the same
`producer_commit`**; the scheduled drift watch covers all seven.

`gate-decision` is vendored in S1 but its runtime semantics activate only in
S4: S1 validates the form and provides the typed record; S2's artifact store
holds it as an immutable artifact that `next_stage` does not consume; S3's
happy path involves no decisions; S4 introduces a dedicated resume-policy
adapter that determines active human evidence and authorizes the transition
out of `needs_human`.

## 8. Slices and exit gates

- **S1 — the boundary** (hand PR): vendoring machinery (PIN, copy-integrity
  test, drift watch per the steward pattern) + `Kapelle.Product` skeleton:
  schema loading, validation, typed records for the seven kinds.
  *Exit: seven vendored contracts, one pin, schema/fixture parity, zero
  runtime references to impresario.*
- **S2 — state and oracle** (hand PR): immutable artifact store (hashing,
  idempotent persist) + `Product.Event` + canonical artifact view and the
  pure next-stage function + parity harness v0 (normalizer, test-only
  oracle adapter, golden set with full provenance, first happy-path parity
  test replaying artifacts without workers).
  *Exit: re-persisting an identical artifact is a no-op; same identity with
  a different hash is a conflict; the canonical view fails closed; the happy
  reference trace normalizes reproducibly.*
- **S3 — minimal e2e** (hand PR): native workers + fake agents via
  behaviour/port + reconciler; happy path Research → Creator → Evaluator →
  Verdict through Oban to the ready case. **The contour unlocks here.**
  *Exit: the Oban happy path reaches `ready_for_business`; crash/retry
  duplicates no artifacts or events; the outcome matches the golden oracle.*
- **S4+ — through the contour** (bounded tasks): the needs-human path with
  resume via gate-decision evidence; the six fault boundaries; the full
  parity matrix (happy / needs-human / invalid-artifact / crash); the
  product loop in LiveView; two-axis verdict reporting.
  *Exit: `needs_human` does not advance without valid active human
  evidence; resume is idempotent; all six fault boundaries and the full
  parity matrix are green.*
- **LiveView invariant across all slices**: it only reads the derived
  projection; its absence or staleness never affects execution.

## 9. Out of scope (M3)

Real LLM/provider agent adapters; backlog ranking (`ranked-backlog`,
`axis-assessment`); QG-5 gate execution (impresario/steward own it — M4 of
the airun arc, already shipped there); `run-record` consumption; any write
path from Kapelle back into impresario.
