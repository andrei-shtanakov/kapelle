# Kapelle — Requirements (Phase 2: M2/M3)

Three requirements, deliberately different in shape: pure domain logic, a
transactional persistence slice, and a read-model/UI slice. They are the
evidence set for spec-runner's TDD lifecycle (#141 slice 3b trigger), so the
variety is the point — a defect class that appears in only one shape is a
property of that shape.

## REQ-101: Deterministic provider fallback

When the routed provider cannot serve a request, the router must fall back
along a chain **declared in the catalog data**, not in code.

Acceptance:

- the fallback chain for an entry comes from `priv/catalog/models.toml`;
- a fallback naming an unknown target is rejected when the catalog is loaded,
  not at call time;
- a fallback cycle is rejected the same way;
- the `Result` records the target that actually served the request, and the
  reasons the earlier targets were rejected, in order;
- a provider `:error` (the provider itself failed) is distinguished from a
  valid `:fail` result (the provider answered, and the answer was a failure);
  only `:error` triggers a fallback;
- no test touches the network.

## REQ-102: Outcome feedback is transactional

`decision_id → verdict → router outcome` is closed exactly once.

Acceptance:

- a typed outcome is persisted after a terminal verdict;
- redelivery is idempotent;
- verdict and outcome are written atomically;
- a late event never overwrites a terminal result;
- a crash between steps leaves no false completion.

## REQ-103: Run detail is visible

The first useful M3 page: a list of runs, and a detail view showing the task,
the decision, the result/verdict and the current status, updating over PubSub.

Acceptance:

- read-only in this slice — cancel/retry are separate;
- the detail view updates when state changes, without a reload;
- LiveView tests, no external network.
