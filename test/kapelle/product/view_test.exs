defmodule Kapelle.Product.ViewTest do
  use Kapelle.DataCase, async: true

  import ExUnit.CaptureLog

  alias Kapelle.Product.{Contracts, Loader, Store, View}
  alias Kapelle.Product.Records.ArtifactRow
  alias Kapelle.Repo

  defp load!(kind, rel) do
    {:ok, record} =
      Loader.load(kind, File.read!(Path.join(Contracts.dir!(kind), rel)))

    record
  end

  defp seed_happy(loop_id) do
    {:ok, _} = Store.put(load!(:idea, "fixtures/valid/idea-001.yaml"), loop_id)
    {:ok, _} = Store.put(load!(:research_pack, "fixtures/valid/rp-001.yaml"), loop_id)
    :ok
  end

  # Template helpers for multi-revision chain tests (Task 4): build a
  # schema-valid doc as an Elixir map, encode it to JSON (StrictParse
  # tries JSON first — JSON is a YAML subset, so this is still going
  # through Loader/Validator, never an unvalidated doc) and load it.
  # Every field not overridden keeps a fixed, FSM-valid default so a test
  # only needs to name the field(s) it is actually exercising.
  defp proposal_doc(overrides) do
    %{
      "proposal_id" => "PP-001",
      "idea_ref" => "idea://IDEA-001",
      "version" => 1,
      "status" => "draft",
      "iteration" => 0,
      "refs" => %{"exchange_log" => "exchange-log://XL-001"},
      "content" => %{"delta_log" => []},
      "created_at" => "2026-08-11T08:00:00Z",
      "updated_at" => "2026-08-12T10:00:00Z"
    }
    |> Map.merge(Map.new(overrides, fn {k, v} -> {to_string(k), v} end))
  end

  defp proposal_record!(overrides) do
    {:ok, record} =
      overrides |> proposal_doc() |> Jason.encode!() |> then(&Loader.load(:product_proposal, &1))

    record
  end

  defp exchange_entry(iteration, actor, kind, ref) do
    %{
      "iteration" => iteration,
      "actor" => actor,
      "artifact_kind" => kind,
      "artifact_ref" => ref,
      "at" => "2026-08-11T09:00:00Z"
    }
  end

  defp exchange_log_record!(entries, overrides \\ []) do
    doc =
      %{"id" => "XL-001", "proposal_ref" => "proposal://PP-001", "entries" => entries}
      |> Map.merge(Map.new(overrides, fn {k, v} -> {to_string(k), v} end))

    {:ok, record} = doc |> Jason.encode!() |> then(&Loader.load(:exchange_log, &1))
    record
  end

  test "a consistent set builds a view keyed by iteration" do
    seed_happy("LOOP-V1")
    assert {:ok, view} = View.build("LOOP-V1")
    assert %{0 => %{"id" => "RP-001"}} = view.research_packs
    assert view.idea["id"]
  end

  test "a stored row whose doc was corrupted post-hoc fails closed on hash mismatch" do
    seed_happy("LOOP-V2")

    row = Repo.get_by!(ArtifactRow, loop_id: "LOOP-V2", kind: "research_pack")
    corrupted = Map.put(row.doc, "gaps", [%{"what" => "tampered", "blocks_approval" => true}])

    Repo.update_all(
      Ecto.Query.from(a in ArtifactRow,
        where: a.loop_id == "LOOP-V2" and a.kind == "research_pack"
      ),
      set: [doc: corrupted]
    )

    assert {:error, {:hash_mismatch, %{kind: :research_pack}}} = View.build("LOOP-V2")
  end

  test "a concept draft with no research pack of its iteration is an impossible sequence" do
    {:ok, _} = Store.put(load!(:idea, "fixtures/valid/idea-001.yaml"), "LOOP-V3")
    {:ok, _} = Store.put(load!(:concept_draft, "fixtures/valid/cd-001.yaml"), "LOOP-V3")
    assert {:error, {:impossible_sequence, _detail}} = View.build("LOOP-V3")
  end

  test "a research pack and concept draft of the same iteration build a full concept_drafts entry" do
    {:ok, _} = Store.put(load!(:idea, "fixtures/valid/idea-001.yaml"), "LOOP-V5")
    {:ok, _} = Store.put(load!(:research_pack, "fixtures/valid/rp-001.yaml"), "LOOP-V5")
    {:ok, _} = Store.put(load!(:concept_draft, "fixtures/valid/cd-001.yaml"), "LOOP-V5")

    assert {:ok, view} = View.build("LOOP-V5")
    assert %{0 => %{"id" => "CD-001"}} = view.concept_drafts
    assert %{0 => %{"id" => "RP-001"}} = view.research_packs
  end

  test "two ideas stored under one loop is a competing artifact" do
    {:ok, _} = Store.put(load!(:idea, "fixtures/valid/idea-001.yaml"), "LOOP-V6")

    other_idea_record = load!(:idea, "fixtures/valid/idea-001.yaml")
    other_doc = Map.put(other_idea_record.doc, "id", "IDEA-002")
    other_record = %{other_idea_record | id: "IDEA-002", doc: other_doc}
    {:ok, _} = Store.put(other_record, "LOOP-V6")

    assert {:error, {:competing_artifacts, %{kind: :idea}}} = View.build("LOOP-V6")
  end

  test "an unknown loop_id with no rows at all builds an empty view" do
    assert {:ok, view} = View.build("LOOP-EMPTY")
    assert view.idea == nil
    assert view.proposal == nil
    assert view.research_packs == %{}
    assert view.concept_drafts == %{}
    assert view.decisions == []
    assert view.dropped == []
  end

  test "a stored gate_decision row whose doc was corrupted post-hoc is dropped, not failed closed, and is visible" do
    {:ok, _} = Store.put(load!(:idea, "fixtures/valid/idea-001.yaml"), "LOOP-V7")
    {:ok, _} = Store.put(load!(:gate_decision, "fixtures/valid/gd-approve.yaml"), "LOOP-V7")

    row = Repo.get_by!(ArtifactRow, loop_id: "LOOP-V7", kind: "gate_decision")
    corrupted = Map.put(row.doc, "reason", "tampered")

    Repo.update_all(
      Ecto.Query.from(a in ArtifactRow,
        where: a.loop_id == "LOOP-V7" and a.kind == "gate_decision"
      ),
      set: [doc: corrupted]
    )

    {result, log} = with_log(fn -> View.build("LOOP-V7") end)

    assert {:ok, %View{decisions: [], dropped: [%{kind: :gate_decision, identity: "GD-001"}]}} =
             result

    assert log =~ "dropping corrupted gate_decision artifact"
  end

  test "a stored loop_resume_decision row whose doc was corrupted post-hoc is dropped, not failed closed, and is visible" do
    {:ok, _} = Store.put(load!(:idea, "fixtures/valid/idea-001.yaml"), "LOOP-V9")
    {:ok, _} = Store.put(load!(:loop_resume_decision, "fixtures/valid/lrd-001.yaml"), "LOOP-V9")

    row = Repo.get_by!(ArtifactRow, loop_id: "LOOP-V9", kind: "loop_resume_decision")
    corrupted = Map.put(row.doc, "reason", "")

    Repo.update_all(
      Ecto.Query.from(a in ArtifactRow,
        where: a.loop_id == "LOOP-V9" and a.kind == "loop_resume_decision"
      ),
      set: [doc: corrupted]
    )

    {result, log} = with_log(fn -> View.build("LOOP-V9") end)

    assert {:ok, %View{dropped: [%{kind: :loop_resume_decision, identity: "LRD-001"}]}} =
             result

    assert log =~ "dropping corrupted loop_resume_decision artifact"
  end

  test "a concept draft whose based_on_research.ref names a different research pack than the one at its own iteration fails closed on reference mismatch" do
    {:ok, _} = Store.put(load!(:idea, "fixtures/valid/idea-001.yaml"), "LOOP-V8")
    {:ok, _} = Store.put(load!(:research_pack, "fixtures/valid/rp-001.yaml"), "LOOP-V8")

    # A second, real research pack under iteration 1 — this is the pack the
    # concept draft below actually needs to agree with once it moves to
    # iteration 1, since RP-001 lives at iteration 0.
    rp2_record = load!(:research_pack, "fixtures/valid/rp-001.yaml")
    rp2_doc = Map.merge(rp2_record.doc, %{"id" => "RP-002", "iteration" => 1})
    rp2_record = %{rp2_record | id: "RP-002", doc: rp2_doc}
    {:ok, _} = Store.put(rp2_record, "LOOP-V8")

    # cd-001 keeps its fixture's based_on_research.ref (research-pack://RP-001)
    # but is stored under iteration 1, where RP-002 — not RP-001 — is the
    # research pack of record.
    cd_record = load!(:concept_draft, "fixtures/valid/cd-001.yaml")
    cd_record = %{cd_record | doc: Map.put(cd_record.doc, "iteration", 1)}
    {:ok, _} = Store.put(cd_record, "LOOP-V8")

    assert {:error,
            {:reference_mismatch,
             %{
               kind: :concept_draft,
               iteration: 1,
               expected: "research-pack://RP-002",
               got: "research-pack://RP-001"
             }}} = View.build("LOOP-V8")
  end

  test "a research pack whose idea_ref names a different idea than the view's fails closed on reference mismatch" do
    {:ok, _} = Store.put(load!(:idea, "fixtures/valid/idea-001.yaml"), "LOOP-V9")

    rp_record = load!(:research_pack, "fixtures/valid/rp-001.yaml")
    rp_record = %{rp_record | doc: Map.put(rp_record.doc, "idea_ref", "idea://IDEA-999")}
    {:ok, _} = Store.put(rp_record, "LOOP-V9")

    assert {:error,
            {:reference_mismatch,
             %{
               kind: :research_pack,
               iteration: 0,
               expected: "idea://IDEA-001",
               got: "idea://IDEA-999"
             }}} = View.build("LOOP-V9")
  end

  test "a product proposal whose idea_ref names a different idea than the view's fails closed on reference mismatch" do
    {:ok, _} = Store.put(load!(:idea, "fixtures/valid/idea-001.yaml"), "LOOP-V10")

    pp_record = load!(:product_proposal, "fixtures/valid/pp-001.yaml")
    pp_record = %{pp_record | doc: Map.put(pp_record.doc, "idea_ref", "idea://IDEA-999")}
    {:ok, _} = Store.put(pp_record, "LOOP-V10")

    assert {:error,
            {:reference_mismatch,
             %{kind: :product_proposal, expected: "idea://IDEA-001", got: "idea://IDEA-999"}}} =
             View.build("LOOP-V10")
  end

  describe "multi-revision proposal chains" do
    test "a consistent v1..v3 chain builds latest + ascending proposal_chain" do
      loop_id = "LOOP-CHAIN-1"

      {:ok, _} =
        Store.put(proposal_record!(version: 1, status: "draft", iteration: 0), loop_id)

      {:ok, _} =
        Store.put(proposal_record!(version: 2, status: "in_iteration", iteration: 0), loop_id)

      {:ok, _} =
        Store.put(proposal_record!(version: 3, status: "in_iteration", iteration: 1), loop_id)

      assert {:ok, view} = View.build(loop_id)
      assert view.proposal["version"] == 3
      assert Enum.map(view.proposal_chain, & &1["version"]) == [1, 2, 3]
    end

    test "a missing middle revision is a revision_gap" do
      loop_id = "LOOP-CHAIN-GAP"

      {:ok, _} = Store.put(proposal_record!(version: 1, status: "draft"), loop_id)
      {:ok, _} = Store.put(proposal_record!(version: 3, status: "in_iteration"), loop_id)

      assert {:error, {:revision_gap, %{kind: :product_proposal, missing: [2]}}} =
               View.build(loop_id)
    end

    test "a multi-snapshot chain not starting at version 1 is a chain_violation :initial_version" do
      loop_id = "LOOP-CHAIN-INITIAL"

      {:ok, _} =
        Store.put(proposal_record!(version: 2, status: "in_iteration", iteration: 0), loop_id)

      {:ok, _} =
        Store.put(proposal_record!(version: 3, status: "in_iteration", iteration: 0), loop_id)

      assert {:error,
              {:chain_violation,
               %{kind: :product_proposal, rule: :initial_version, detail: %{lowest_version: 2}}}} =
               View.build(loop_id)
    end

    test "a single stored snapshot at a later version is NOT an :initial_version violation (golden-replay case)" do
      loop_id = "LOOP-CHAIN-SINGLE-LATE"

      {:ok, _} =
        Store.put(
          proposal_record!(version: 5, status: "ready_for_business", iteration: 1),
          loop_id
        )

      assert {:ok, view} = View.build(loop_id)
      assert view.proposal["version"] == 5
      assert [%{"version" => 5}] = view.proposal_chain
    end

    test "idea_ref drifting across revisions is a chain_violation :identity_drift" do
      loop_id = "LOOP-CHAIN-DRIFT"

      {:ok, _} =
        Store.put(
          proposal_record!(version: 1, status: "draft", idea_ref: "idea://IDEA-001"),
          loop_id
        )

      {:ok, _} =
        Store.put(
          proposal_record!(version: 2, status: "in_iteration", idea_ref: "idea://IDEA-002"),
          loop_id
        )

      assert {:error,
              {:chain_violation,
               %{
                 kind: :product_proposal,
                 rule: :identity_drift,
                 detail: %{expected: "idea://IDEA-001", got: "idea://IDEA-002"}
               }}} = View.build(loop_id)
    end

    test "a status move outside the reference FSM (not via a terminal snapshot) is a chain_violation :fsm_regression" do
      loop_id = "LOOP-CHAIN-FSM"

      {:ok, _} = Store.put(proposal_record!(version: 1, status: "draft"), loop_id)
      {:ok, _} = Store.put(proposal_record!(version: 2, status: "in_iteration"), loop_id)
      {:ok, _} = Store.put(proposal_record!(version: 3, status: "draft"), loop_id)

      assert {:error,
              {:chain_violation,
               %{
                 kind: :product_proposal,
                 rule: :fsm_regression,
                 detail: %{from: "in_iteration", to: "draft"}
               }}} = View.build(loop_id)
    end

    test "iteration decreasing across revisions is a chain_violation :iteration_decrease" do
      loop_id = "LOOP-CHAIN-ITER-DEC"

      {:ok, _} = Store.put(proposal_record!(version: 1, status: "draft", iteration: 0), loop_id)

      {:ok, _} =
        Store.put(proposal_record!(version: 2, status: "in_iteration", iteration: 1), loop_id)

      {:ok, _} =
        Store.put(proposal_record!(version: 3, status: "in_iteration", iteration: 0), loop_id)

      assert {:error,
              {:chain_violation,
               %{
                 kind: :product_proposal,
                 rule: :iteration_decrease,
                 detail: %{from_iteration: 1, to_iteration: 0}
               }}} = View.build(loop_id)
    end

    test "a revision stored after a terminal (ready_for_business) snapshot is a chain_violation :terminal_superseded" do
      loop_id = "LOOP-CHAIN-TERMINAL"

      {:ok, _} = Store.put(proposal_record!(version: 1, status: "draft", iteration: 0), loop_id)

      {:ok, _} =
        Store.put(proposal_record!(version: 2, status: "in_iteration", iteration: 0), loop_id)

      {:ok, _} =
        Store.put(
          proposal_record!(version: 3, status: "ready_for_business", iteration: 1),
          loop_id
        )

      {:ok, _} =
        Store.put(proposal_record!(version: 4, status: "in_iteration", iteration: 1), loop_id)

      assert {:error,
              {:chain_violation,
               %{
                 kind: :product_proposal,
                 rule: :terminal_superseded,
                 detail: %{terminal_version: 3, next_version: 4}
               }}} = View.build(loop_id)
    end
  end

  describe "N2 reference edges: research_pack/concept_draft/exchange_log against idea/proposal" do
    test "a concept draft whose idea_ref names a different idea than the view's fails closed on reference mismatch" do
      {:ok, _} = Store.put(load!(:idea, "fixtures/valid/idea-001.yaml"), "LOOP-N2-CD-IDEA")
      {:ok, _} = Store.put(load!(:research_pack, "fixtures/valid/rp-001.yaml"), "LOOP-N2-CD-IDEA")

      cd_record = load!(:concept_draft, "fixtures/valid/cd-001.yaml")
      cd_record = %{cd_record | doc: Map.put(cd_record.doc, "idea_ref", "idea://IDEA-999")}
      {:ok, _} = Store.put(cd_record, "LOOP-N2-CD-IDEA")

      assert {:error,
              {:reference_mismatch,
               %{
                 kind: :concept_draft,
                 iteration: 0,
                 expected: "idea://IDEA-001",
                 got: "idea://IDEA-999"
               }}} = View.build("LOOP-N2-CD-IDEA")
    end

    test "a research pack whose proposal_ref names a different proposal than the view's fails closed on reference mismatch" do
      loop_id = "LOOP-N2-RP-PROPOSAL"
      {:ok, _} = Store.put(load!(:idea, "fixtures/valid/idea-001.yaml"), loop_id)
      {:ok, _} = Store.put(proposal_record!(version: 1, status: "draft"), loop_id)

      rp_record = load!(:research_pack, "fixtures/valid/rp-001.yaml")
      rp_record = %{rp_record | doc: Map.put(rp_record.doc, "proposal_ref", "proposal://PP-999")}
      {:ok, _} = Store.put(rp_record, loop_id)

      assert {:error,
              {:reference_mismatch,
               %{
                 kind: :research_pack,
                 iteration: 0,
                 expected: "proposal://PP-001",
                 got: "proposal://PP-999"
               }}} = View.build(loop_id)
    end

    test "a concept draft whose proposal_ref names a different proposal than the view's fails closed on reference mismatch" do
      loop_id = "LOOP-N2-CD-PROPOSAL"
      {:ok, _} = Store.put(load!(:idea, "fixtures/valid/idea-001.yaml"), loop_id)
      {:ok, _} = Store.put(proposal_record!(version: 1, status: "draft"), loop_id)
      {:ok, _} = Store.put(load!(:research_pack, "fixtures/valid/rp-001.yaml"), loop_id)

      cd_record = load!(:concept_draft, "fixtures/valid/cd-001.yaml")
      cd_record = %{cd_record | doc: Map.put(cd_record.doc, "proposal_ref", "proposal://PP-999")}
      {:ok, _} = Store.put(cd_record, loop_id)

      assert {:error,
              {:reference_mismatch,
               %{
                 kind: :concept_draft,
                 iteration: 0,
                 expected: "proposal://PP-001",
                 got: "proposal://PP-999"
               }}} = View.build(loop_id)
    end

    test "an exchange log whose proposal_ref names a different proposal than the view's fails closed on reference mismatch" do
      loop_id = "LOOP-N2-XL-PROPOSAL"
      {:ok, _} = Store.put(load!(:idea, "fixtures/valid/idea-001.yaml"), loop_id)
      {:ok, _} = Store.put(proposal_record!(version: 1, status: "draft"), loop_id)

      xl_record =
        exchange_log_record!(
          [exchange_entry(0, "researcher", "research_pack", "research-pack://RP-001")],
          proposal_ref: "proposal://PP-999"
        )

      {:ok, _} = Store.put(xl_record, loop_id)

      assert {:error,
              {:reference_mismatch,
               %{kind: :exchange_log, expected: "proposal://PP-001", got: "proposal://PP-999"}}} =
               View.build(loop_id)
    end

    test "reference checks against idea/proposal are skipped when idea/proposal are absent from the view" do
      loop_id = "LOOP-N2-NO-IDEA-NO-PROPOSAL"

      xl_record =
        exchange_log_record!([
          exchange_entry(0, "researcher", "research_pack", "research-pack://RP-001")
        ])

      {:ok, _} = Store.put(xl_record, loop_id)

      assert {:ok, view} = View.build(loop_id)
      assert view.exchange_log["id"] == "XL-001"
    end
  end

  describe "exchange_log chains" do
    test "a consistent multi-revision exchange log builds latest + ascending exchange_log_chain" do
      loop_id = "LOOP-XL-CHAIN"

      e0 = exchange_entry(0, "researcher", "research_pack", "research-pack://RP-001")
      e1 = exchange_entry(0, "creator", "concept_draft", "concept-draft://CD-001")

      {:ok, _} = Store.put(exchange_log_record!([e0]), loop_id)
      {:ok, _} = Store.put(exchange_log_record!([e0, e1]), loop_id)

      assert {:ok, view} = View.build(loop_id)
      assert length(view.exchange_log["entries"]) == 2
      assert Enum.map(view.exchange_log_chain, &length(&1["entries"])) == [1, 2]
    end

    test "a later snapshot whose prefix diverges from an earlier snapshot's entries is a chain_violation :history_rewritten" do
      loop_id = "LOOP-XL-REWRITE"

      e0 = exchange_entry(0, "researcher", "research_pack", "research-pack://RP-001")
      e0_mutated = exchange_entry(0, "researcher", "research_pack", "research-pack://RP-999")
      e1 = exchange_entry(0, "creator", "concept_draft", "concept-draft://CD-001")

      {:ok, _} = Store.put(exchange_log_record!([e0]), loop_id)
      {:ok, _} = Store.put(exchange_log_record!([e0_mutated, e1]), loop_id)

      assert {:error,
              {:chain_violation,
               %{kind: :exchange_log, rule: :history_rewritten, detail: %{to_revision: 2}}}} =
               View.build(loop_id)
    end

    test "entries with a decreasing iteration are a chain_violation :entry_order" do
      loop_id = "LOOP-XL-ORDER-ITER"

      e0 = exchange_entry(1, "researcher", "research_pack", "research-pack://RP-002")
      e1 = exchange_entry(0, "researcher", "research_pack", "research-pack://RP-001")

      {:ok, _} = Store.put(exchange_log_record!([e0, e1]), loop_id)

      assert {:error,
              {:chain_violation,
               %{kind: :exchange_log, rule: :entry_order, detail: %{reason: :iteration_decrease}}}} =
               View.build(loop_id)
    end

    test "a creator entry preceding the researcher entry of the same iteration is a chain_violation :entry_order" do
      loop_id = "LOOP-XL-ORDER-ACTOR"

      creator_first = exchange_entry(0, "creator", "concept_draft", "concept-draft://CD-001")

      researcher_second =
        exchange_entry(0, "researcher", "research_pack", "research-pack://RP-001")

      {:ok, _} = Store.put(exchange_log_record!([creator_first, researcher_second]), loop_id)

      assert {:error,
              {:chain_violation,
               %{
                 kind: :exchange_log,
                 rule: :entry_order,
                 detail: %{reason: :researcher_after_creator, iteration: 0}
               }}} = View.build(loop_id)
    end

    test "an iteration with a creator entry but no researcher entry of its own is a chain_violation :missing_researcher_entry" do
      loop_id = "LOOP-XL-NO-RESEARCHER"

      entries = [
        exchange_entry(0, "creator", "concept_draft", "concept-draft://CD-001"),
        exchange_entry(0, "orchestration", "product_proposal_patch", "proposal://PP-001"),
        exchange_entry(1, "researcher", "research_pack", "research-pack://RP-002"),
        exchange_entry(1, "creator", "concept_draft", "concept-draft://CD-002"),
        exchange_entry(1, "orchestration", "product_proposal_patch", "proposal://PP-001")
      ]

      {:ok, _} = Store.put(exchange_log_record!(entries), loop_id)

      assert {:error,
              {:chain_violation,
               %{kind: :exchange_log, rule: :missing_researcher_entry, detail: %{iteration: 0}}}} =
               View.build(loop_id)
    end
  end
end
