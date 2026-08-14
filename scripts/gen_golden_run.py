#!/usr/bin/env python3
"""Drive the pinned producer's deterministic happy-path loop to READY.

Ported from `tests/test_loop.py`'s HAPPY_SCRIPT fixture at the pinned commit
(see scripts/gen_golden.sh) rather than imported: importing the producer's
test module pulls in its dev-only `pytest` dependency, which the extracted
tree's own `pip install -e` step (main dependencies only) does not provision.

Usage: gen_golden_run.py <extracted-producer-root> <output-workspace-dir>
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


def main(argv: list[str]) -> None:
    root = Path(argv[1]).resolve()
    workspace = Path(argv[2]).resolve()

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
    result = run_loop(
        workspace, contracts_dir, ScriptedAgent(HAPPY_SCRIPT), now_iso=NOW
    )
    if result.verdict != "ready_for_business":
        raise SystemExit(
            f"expected ready_for_business, got {result.verdict}: {result.stop_reason}"
        )
    print(
        f"verdict={result.verdict} iteration={result.iteration} "
        f"proposal_version={result.proposal_version}"
    )


if __name__ == "__main__":
    main(sys.argv)
