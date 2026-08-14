defmodule Kapelle.Product.StoreTest do
  use Kapelle.DataCase, async: true

  alias Kapelle.Product.{Event, Events, Loader, Store}

  defp rp_record do
    {:ok, record} =
      Loader.load(
        :research_pack,
        File.read!(
          Path.join(
            Kapelle.Product.Contracts.dir!(:research_pack),
            "fixtures/valid/rp-001.yaml"
          )
        )
      )

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
end
