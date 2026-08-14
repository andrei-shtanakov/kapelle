defmodule Kapelle.Product.StoreTest do
  use Kapelle.DataCase, async: true

  alias Kapelle.Product.{Contracts, Event, Events, Loader, Store}

  defp rp_record do
    {:ok, record} =
      Loader.load(
        :research_pack,
        File.read!(
          Path.join(
            Contracts.dir!(:research_pack),
            "fixtures/valid/rp-001.yaml"
          )
        )
      )

    record
  end

  # Schema-valid product_proposal doc through Loader, overriding only
  # `version` — the revision-bearing field for this kind (owner's
  # decision, 2026-08-14). Based on the vendored valid fixture pp-001.
  defp proposal_record(version: version) do
    yaml = """
    proposal_id: PP-001
    idea_ref: idea://IDEA-001
    version: #{version}
    status: business_approved
    iteration: 2
    refs:
      latest_research_pack: research-pack://RP-001
      latest_concept_draft: concept-draft://CD-001
      exchange_log: exchange-log://XL-001
    content:
      research_summary: "Доля типовых запросов подтверждена; ёмкость SMB оценена."
      concept: "Self-service портал; модели Premium-тариф / плата за инцидент."
      economics_draft: "Себестоимость-гипотеза и бюджет запроса v1."
    created_at: 2026-08-11T08:00:00Z
    updated_at: 2026-08-12T10:00:00Z
    """

    {:ok, record} = Loader.load(:product_proposal, yaml)
    record
  end

  test "first put inserts and broadcasts one post-commit event" do
    :ok = Events.subscribe("LOOP-T1")
    assert {:ok, :inserted} = Store.put(rp_record(), "LOOP-T1")

    assert_receive %Event{
      loop_id: "LOOP-T1",
      kind: :artifact_stored,
      artifact_kind: :research_pack,
      artifact_ref: "research-pack://RP-001",
      artifact_hash: "sha256:" <> _
    }
  end

  test "identical identity + identical canonical hash is a no-op and NO event" do
    assert {:ok, :inserted} = Store.put(rp_record(), "LOOP-T2")
    :ok = Events.subscribe("LOOP-T2")
    assert {:ok, :noop} = Store.put(rp_record(), "LOOP-T2")
    refute_receive %Event{}, 200
  end

  test "identical identity + different hash is a typed conflict and NO event" do
    record = rp_record()
    assert {:ok, :inserted} = Store.put(record, "LOOP-T3")
    :ok = Events.subscribe("LOOP-T3")

    mutated = %{record | doc: Map.put(record.doc, "gaps", ["tampered"])}

    assert {:error,
            {:artifact_conflict, :research_pack, "RP-001", "sha256:" <> _, "sha256:" <> _}} =
             Store.put(mutated, "LOOP-T3")

    refute_receive %Event{}, 200
  end

  test "all/1 returns the loop's artifacts with typed kinds" do
    assert {:ok, :inserted} = Store.put(rp_record(), "LOOP-T4")

    assert [%{kind: :research_pack, id: "RP-001", doc: %{"id" => "RP-001"}}] =
             Store.all("LOOP-T4")
  end

  test "a new admissible revision of the proposal is a new immutable row, event carries the revision" do
    v1 = proposal_record(version: 1)
    v2 = proposal_record(version: 2)
    :ok = Events.subscribe("LOOP-R1")
    assert {:ok, :inserted} = Store.put(v1, "LOOP-R1")
    assert_receive %Event{artifact_revision: 1}
    assert {:ok, :inserted} = Store.put(v2, "LOOP-R1")
    assert_receive %Event{artifact_revision: 2}

    assert [%{revision: 1}, %{revision: 2}] =
             Store.all("LOOP-R1")
             |> Enum.filter(&(&1.kind == :product_proposal))
             |> Enum.sort_by(& &1.revision)
  end

  test "same revision with different content is a conflict; a re-put of the same bytes is a no-op" do
    v2 = proposal_record(version: 2)
    assert {:ok, :inserted} = Store.put(v2, "LOOP-R2")
    assert {:ok, :noop} = Store.put(v2, "LOOP-R2")

    # put_in over the `v2.doc["content"]` path already returns the whole
    # updated Record — wrapping it again in `%{v2 | doc: ...}` would nest
    # a Record where a map is expected.
    mutated = put_in(v2.doc["content"], %{"delta_log" => ["x"]})

    assert {:error, {:artifact_conflict, :product_proposal, _, _, _}} =
             Store.put(mutated, "LOOP-R2")
  end

  test "a late lower revision still inserts — Store never polices latest, the View does" do
    v2 = proposal_record(version: 2)
    v1 = proposal_record(version: 1)
    assert {:ok, :inserted} = Store.put(v2, "LOOP-R3")
    assert {:ok, :inserted} = Store.put(v1, "LOOP-R3")

    assert [%{revision: 1}, %{revision: 2}] =
             Store.all("LOOP-R3")
             |> Enum.filter(&(&1.kind == :product_proposal))
             |> Enum.sort_by(& &1.revision)
  end
end
