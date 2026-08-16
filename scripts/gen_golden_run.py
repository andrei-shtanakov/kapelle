#!/usr/bin/env python3
"""Drive one of the pinned producer's deterministic loops to its terminal verdict.

Ported from `tests/test_loop.py`'s fixtures at the pinned commit (see
scripts/gen_golden.sh) rather than imported: importing the producer's test
module pulls in its dev-only `pytest` dependency, which the extracted tree's
own `pip install -e` step (main dependencies only) does not provision.

Both scripts are the producer's own — `HAPPY_SCRIPT` and `STUCK_SCRIPT`. The
needs-human oracle must express the producer's semantics, not this project's
expectation of them, so it is copied from the source of truth rather than
invented here.

Usage: gen_golden_run.py <extracted-producer-root> <output-workspace-dir> [scenario]
       scenario: happy (default) | needs_human
"""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

import yaml

NOW = "2026-08-12T18:00:00Z"


def _idea() -> dict[str, Any]:
    return {
        "id": "IDEA-001",
        "title": "Loop test idea",
        "date": "2026-08-12",
        "source": {"kind": "internal", "ref": "test"},
        "priority": "high",
        "business_attractiveness": 4,
        "status": "selected",
        "hypothesis": "h",
    }


def _actor(role: str) -> dict[str, Any]:
    return {
        "kind": "agent",
        "id": role,
        "model": "vendor/model-x",
        "prompt_version": f"{role}/v1",
    }


def _rp(num: int, iteration: int, *, gap_open: bool) -> dict[str, Any]:
    return {
        "id": f"RP-{num:03d}",
        "idea_ref": "idea://IDEA-001",
        "proposal_ref": "proposal://PP-001",
        "iteration": iteration,
        "findings": [{"claim": "claim", "source_ref": "ref://x", "confidence": "high"}],
        "constraints": [],
        "gaps": [
            {
                "what": "critical gap",
                "blocks_approval": True,
                **({} if gap_open else {"closed": True}),
            }
        ],
        "brief_for_creator": "brief",
        "requests_to_creator": [],
        "produced_by": _actor("researcher"),
        "produced_at": NOW,
    }


def _cd(
    num: int,
    iteration: int,
    rp_num: int,
    *,
    assumption_open: bool,
    requests: list[str] | None = None,
) -> dict[str, Any]:
    return {
        "id": f"CD-{num:03d}",
        "idea_ref": "idea://IDEA-001",
        "proposal_ref": "proposal://PP-001",
        "iteration": iteration,
        "based_on_research": {
            "ref": f"research-pack://RP-{rp_num:03d}",
            "iteration": iteration,
        },
        "value_prop": "value",
        "alternatives": [
            {"direction": "a", "summary": "s"},
            {"direction": "b", "summary": "s"},
            {"direction": "c", "summary": "s"},
        ],
        "chosen_direction": {"direction": "a", "why": "w"},
        "business_models": ["m"],
        "assumptions": [
            {
                "text": "critical assumption",
                "blocks_approval": True,
                **(
                    {}
                    if assumption_open
                    else {"answered_by": f"research-pack://RP-{rp_num:03d}"}
                ),
            }
        ],
        "requests_to_researcher": requests or [],
        "proposal_delta": f"delta {iteration}",
        "produced_by": _actor("creator"),
        "produced_at": NOW,
    }


# Byte-for-byte the HAPPY_SCRIPT fixture in tests/test_loop.py at the pin:
# iteration 0 leaves a critical gap AND a critical assumption AND an open
# request open (advances rather than terminating); iteration 1 closes the
# gap (gap_open=False -> "closed": true) and answers the assumption
# (assumption_open=False -> "answered_by" set), with no further requests,
# so the loop reaches READY by exercising both closing rules, not just the
# simplest possible path.
HAPPY_SCRIPT = {
    "researcher": {
        0: _rp(1, 0, gap_open=True),
        1: _rp(2, 1, gap_open=False),
    },
    "creator": {
        0: _cd(1, 0, 1, assumption_open=True, requests=["check the gap"]),
        1: _cd(2, 1, 2, assumption_open=False),
    },
}

# Byte-for-byte the STUCK_SCRIPT fixture in tests/test_loop.py at the pin, and
# the producer's own `test_stuck_loop_needs_human` asserts what it produces:
# verdict `needs_human`, a stop reason naming the open criticals, and the
# proposal left `in_iteration` — a hold, not a failure. Every iteration leaves
# the critical gap open and the critical assumption unanswered, so
# `open_criticals/2` never empties and the last iteration terminates on
# `max_iterations reached with open critical items: ...`.
STUCK_SCRIPT = {
    "researcher": {0: _rp(1, 0, gap_open=True), 1: _rp(2, 1, gap_open=True)},
    "creator": {
        0: _cd(1, 0, 1, assumption_open=True),
        1: _cd(2, 1, 2, assumption_open=True),
    },
}

# The resume scenario replays the producer's own `test_needs_human_resume_path`:
# STUCK to `needs_human`, a human `resume_loop` (which, at the pinned commit,
# authors an immutable loop-resume-decision into decisions/), then iteration 2
# closes the gap and answers the assumption -> `ready_for_business`.
RESUME_UNSTUCK_SCRIPT = {
    "researcher": {**STUCK_SCRIPT["researcher"], 2: _rp(3, 2, gap_open=False)},
    "creator": {**STUCK_SCRIPT["creator"], 2: _cd(3, 2, 3, assumption_open=False)},
}

# Byte-for-byte the `broken` fixture of the producer's own
# `test_invalid_artifact_fails_closed`: the researcher's iteration-0 document
# violates the research-pack schema (empty brief_for_creator), the runner
# refuses to persist it (artifact_rejected in the trace) and stops fail-closed
# with verdict `failed` at iteration 0.
INVALID_ARTIFACT_SCRIPT = {
    "researcher": {0: {**_rp(1, 0, gap_open=True), "brief_for_creator": ""}},
    "creator": {},
}

SCENARIOS = {
    "happy": (HAPPY_SCRIPT, "ready_for_business"),
    "needs_human": (STUCK_SCRIPT, "needs_human"),
    "resume": (STUCK_SCRIPT, "needs_human"),
    "invalid_artifact": (INVALID_ARTIFACT_SCRIPT, "failed"),
}


def main(argv: list[str]) -> None:
    # The required arguments are checked like the optional one (Copilot,
    # PR #18): this is a hand-run generator, and an IndexError is a worse
    # answer to a mistyped invocation than the usage line it already has.
    if len(argv) < 3:
        raise SystemExit(
            "usage: gen_golden_run.py <extracted-producer-root> "
            "<output-workspace-dir> [happy|needs_human|resume|invalid_artifact]"
        )
    root = Path(argv[1]).resolve()
    workspace = Path(argv[2]).resolve()
    scenario = argv[3] if len(argv) > 3 else "happy"
    if scenario not in SCENARIOS:
        raise SystemExit(f"unknown scenario {scenario!r}; expected one of {sorted(SCENARIOS)}")
    if not (root / "contracts").is_dir():
        raise SystemExit(f"{root} does not look like a producer checkout: no contracts/ in it")
    script, expected_verdict = SCENARIOS[scenario]

    from impresario.agents import ScriptedAgent
    from impresario.loop import init_loop, run_loop

    contracts_dir = root / "contracts"
    idea_file = workspace.parent / "idea-source.yaml"
    idea_file.write_text(
        yaml.safe_dump(_idea(), allow_unicode=True, sort_keys=False),
        encoding="utf-8",
    )

    init_loop(
        workspace,
        idea_file,
        contracts_dir,
        loop_id="LOOP-001",
        proposal_id="PP-001",
        exchange_log_id="XL-001",
        max_iterations=2,
        now_iso=NOW,
    )
    result = run_loop(workspace, contracts_dir, ScriptedAgent(script), now_iso=NOW)
    if result.verdict != expected_verdict:
        raise SystemExit(
            f"expected {expected_verdict}, got {result.verdict}: {result.stop_reason}"
        )

    if scenario == "resume":
        from impresario.loop import resume_loop

        decision_ref = resume_loop(
            workspace,
            contracts_dir,
            max_iterations=3,
            actor="andrei",
            reason="owner resolved the blocking critical items",
            now_iso=NOW,
        )
        print(f"resumed via {decision_ref}")
        result = run_loop(
            workspace,
            contracts_dir,
            ScriptedAgent(RESUME_UNSTUCK_SCRIPT),
            now_iso=NOW,
        )
        if result.verdict != "ready_for_business":
            raise SystemExit(
                f"expected ready_for_business after resume, got "
                f"{result.verdict}: {result.stop_reason}"
            )
    print(
        f"verdict={result.verdict} iteration={result.iteration} "
        f"proposal_version={result.proposal_version}"
    )


if __name__ == "__main__":
    main(sys.argv)
