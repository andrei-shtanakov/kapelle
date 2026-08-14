defmodule Kapelle.Product.ViewTest do
  use Kapelle.DataCase, async: true

  alias Kapelle.Product.{Loader, Store, View}
  alias Kapelle.Product.Records.ArtifactRow
  alias Kapelle.Repo

  defp load!(kind, rel) do
    {:ok, record} =
      Loader.load(kind, File.read!(Path.join(Kapelle.Product.Contracts.dir!(kind), rel)))

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
    assert view.loop_state == nil
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

  test "loop_state is carried as projection but its absence or presence never fails the view" do
    seed_happy("LOOP-V4")
    assert {:ok, %View{loop_state: nil}} = View.build("LOOP-V4")
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
    assert view.loop_state == nil
  end

  test "a stored gate_decision row whose doc was corrupted post-hoc is dropped, not failed closed" do
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

    assert {:ok, %View{decisions: []}} = View.build("LOOP-V7")
  end
end
