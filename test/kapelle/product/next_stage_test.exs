defmodule Kapelle.Product.NextStageTest do
  use ExUnit.Case, async: true

  alias Kapelle.Product.{NextStage, View}

  defp view(attrs) do
    struct!(%View{loop_id: "LOOP-NS"}, attrs)
  end

  defp rp(iteration, gaps \\ []) do
    %{"iteration" => iteration, "gaps" => gaps}
  end

  defp cd(iteration, assumptions \\ [], requests \\ []) do
    %{
      "iteration" => iteration,
      "assumptions" => assumptions,
      "requests_to_researcher" => requests
    }
  end

  defp open_gap(what), do: %{"what" => what, "blocks_approval" => true}
  defp closed_gap(what), do: %{"what" => what, "blocks_approval" => true, "closed" => true}
  defp non_blocking_gap(what), do: %{"what" => what, "blocks_approval" => false}

  defp open_assumption(text), do: %{"text" => text, "blocks_approval" => true}

  defp answered_assumption(text),
    do: %{"text" => text, "blocks_approval" => true, "answered_by" => "research-pack://RP-002"}

  defp waived_assumption(text),
    do: %{"text" => text, "blocks_approval" => true, "human_waiver" => "sponsor waived it"}

  test "an empty view runs research at iteration 0" do
    assert NextStage.compute(view(%{}), 3) == {:run, {:research, 0}}
  end

  test "a research pack with no concept draft runs concept at the same iteration" do
    v = view(%{research_packs: %{0 => rp(0)}})
    assert NextStage.compute(v, 3) == {:run, {:concept, 0}}
  end

  test "a research pack and concept draft with no applied proposal delta runs apply" do
    v = view(%{research_packs: %{0 => rp(0)}, concept_drafts: %{0 => cd(0)}, proposal: nil})
    assert NextStage.compute(v, 3) == {:run, {:apply, 0}}
  end

  test "an applied delta with no open gaps, assumptions, or requests is ready" do
    v =
      view(%{
        research_packs: %{0 => rp(0, [non_blocking_gap("SMB capacity"), closed_gap("pricing")])},
        concept_drafts: %{0 => cd(0, [answered_assumption("payer readiness")])},
        proposal: %{"iteration" => 0}
      })

    assert {:terminal, :ready, reason} = NextStage.compute(v, 3)
    assert reason =~ "no open critical"
  end

  test "open critical items mid-loop advance research to the next iteration" do
    v =
      view(%{
        research_packs: %{0 => rp(0, [open_gap("SMB capacity unknown")])},
        concept_drafts: %{0 => cd(0)},
        proposal: %{"iteration" => 0}
      })

    assert NextStage.compute(v, 3) == {:run, {:research, 1}}
  end

  test "open critical items at the last iteration need a human" do
    v =
      view(%{
        research_packs: %{0 => rp(0, [open_gap("SMB capacity unknown")])},
        concept_drafts: %{0 => cd(0, [open_assumption("payer readiness unconfirmed")])},
        proposal: %{"iteration" => 0}
      })

    assert {:terminal, :needs_human, reason} = NextStage.compute(v, 1)

    # Pinned exact equality, not =~: the producer's open_criticals/2 lists
    # assumptions before gaps (impresario loop.py:419-433) — a silent order
    # swap here would never fail this test if it only matched a substring.
    assert reason ==
             "max_iterations reached with open critical items: " <>
               "assumption: payer readiness unconfirmed; gap: SMB capacity unknown"
  end

  test "open assumptions from the concept draft count as critical items too" do
    v =
      view(%{
        research_packs: %{0 => rp(0)},
        concept_drafts: %{0 => cd(0, [open_assumption("payer readiness unconfirmed")])},
        proposal: %{"iteration" => 0}
      })

    assert {:terminal, :needs_human, reason} = NextStage.compute(v, 1)
    assert reason =~ "assumption: payer readiness unconfirmed"
  end

  test "a human-waived assumption is closed and does not block readiness" do
    v =
      view(%{
        research_packs: %{0 => rp(0)},
        concept_drafts: %{0 => cd(0, [waived_assumption("payer readiness unconfirmed")])},
        proposal: %{"iteration" => 0}
      })

    assert {:terminal, :ready, _reason} = NextStage.compute(v, 1)
  end

  test "open requests to the researcher with no other issues still block readiness at max" do
    v =
      view(%{
        research_packs: %{0 => rp(0)},
        concept_drafts: %{0 => cd(0, [], ["confirm target segment"])},
        proposal: %{"iteration" => 0}
      })

    assert {:terminal, :needs_human, reason} = NextStage.compute(v, 1)
    assert reason =~ "1 open request"
  end

  test "open requests to the researcher with room left advance to the next iteration" do
    v =
      view(%{
        research_packs: %{0 => rp(0)},
        concept_drafts: %{0 => cd(0, [], ["confirm target segment"])},
        proposal: %{"iteration" => 0}
      })

    assert NextStage.compute(v, 2) == {:run, {:research, 1}}
  end

  test "a round's own fresh proposal (iteration 0, empty delta_log) still runs apply — not evaluate" do
    # Regression (Task 7): `Loop.start`'s real initial snapshot is
    # `iteration: 0, content: %{"delta_log" => []}` — the exact
    # `iteration` value round 0's own apply will later produce too.
    # Reading `delta_applied?` off the bare `iteration` field alone
    # cannot tell these apart; it must consult `content.delta_log`
    # once `content` is present.
    v =
      view(%{
        research_packs: %{0 => rp(0, [open_gap("SMB capacity unknown")])},
        concept_drafts: %{0 => cd(0)},
        proposal: %{"iteration" => 0, "content" => %{"delta_log" => []}}
      })

    assert NextStage.compute(v, 3) == {:run, {:apply, 0}}
  end

  test "delta_applied?/2 consults content.delta_log by entry iteration, not the bare iteration field" do
    proposal = %{"iteration" => 0, "content" => %{"delta_log" => [%{"iteration" => 0}]}}

    assert NextStage.delta_applied?(proposal, 0)
    refute NextStage.delta_applied?(proposal, 1)
    refute NextStage.delta_applied?(%{"iteration" => 5, "content" => %{"delta_log" => []}}, 0)
    assert NextStage.delta_applied?(%{"iteration" => 0}, 0)
    refute NextStage.delta_applied?(nil, 0)
  end

  test "a fully replayed multi-iteration view reaches ready instead of re-running iteration 0" do
    # Regression: iteration 0 left an open gap/assumption/request (so, taken
    # alone, it would "advance" to research 1), but the view already holds
    # iteration 1's artifacts closing them out — a completed/resumed loop
    # replayed whole, as the golden happy-path fixture does. The walk must
    # follow through to iteration 1's own verdict, not get stuck re-deciding
    # iteration 0 forever.
    v =
      view(%{
        research_packs: %{
          0 => rp(0, [open_gap("critical gap")]),
          1 => rp(1, [closed_gap("critical gap")])
        },
        concept_drafts: %{
          0 => cd(0, [open_assumption("critical assumption")], ["check the gap"]),
          1 => cd(1, [answered_assumption("critical assumption")])
        },
        proposal: %{"iteration" => 1}
      })

    assert {:terminal, :ready, _reason} = NextStage.compute(v, 2)
  end
end
