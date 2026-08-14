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
end
