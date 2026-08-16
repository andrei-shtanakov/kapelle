defmodule Kapelle.Product.LoopsTest do
  @moduledoc """
  `product_loops` is loop configuration plus a best-effort state
  projection — not the authoritative artifact store (design doc §5,
  owner's loop-state-leaves-the-store decision, 2026-08-14).
  """

  use Kapelle.DataCase, async: true

  alias Kapelle.Product.Loops

  defp valid_attrs(loop_id) do
    %{
      loop_id: loop_id,
      idea_identity: "IDEA-001",
      proposal_id: "PP-001",
      exchange_log_id: "XL-001",
      max_iterations: 2,
      agent: "fixture:happy"
    }
  end

  test "create/1 persists a loop config with default running status and no projection yet" do
    assert {:ok, row} = Loops.create(valid_attrs("LOOP-L1"))
    assert row.loop_id == "LOOP-L1"
    assert row.status == "running"
    assert row.stop_reason == nil
    assert row.latest_state == nil
  end

  test "create/1 refuses an already-initialized loop_id" do
    assert {:ok, _} = Loops.create(valid_attrs("LOOP-L2"))
    assert {:error, :already_initialized} = Loops.create(valid_attrs("LOOP-L2"))
  end

  test "get!/1 fetches the loop config by loop_id" do
    {:ok, _} = Loops.create(valid_attrs("LOOP-L3"))
    assert %{loop_id: "LOOP-L3", agent: "fixture:happy"} = Loops.get!("LOOP-L3")
  end

  test "set_status/3 is a monotonic terminal transition: a later status cannot override an earlier terminal one" do
    {:ok, _} = Loops.create(valid_attrs("LOOP-L4"))

    assert {:ok, :transitioned} =
             Loops.set_status("LOOP-L4", "ready", "no open critical items")

    assert {:error, :already_terminal} = Loops.set_status("LOOP-L4", "failed", "late failure")

    assert %{status: "ready", stop_reason: "no open critical items"} = Loops.get!("LOOP-L4")
  end

  test "put_state_projection/2 overwrites latest_state, idempotently, regardless of status" do
    {:ok, _} = Loops.create(valid_attrs("LOOP-L5"))
    state_doc = %{"loop_id" => "LOOP-L5", "max_iterations" => 2}

    assert {:ok, %{latest_state: ^state_doc}} =
             Loops.put_state_projection("LOOP-L5", state_doc)

    assert {:ok, %{latest_state: ^state_doc}} =
             Loops.put_state_projection("LOOP-L5", state_doc)

    assert {:ok, :transitioned} = Loops.set_status("LOOP-L5", "ready", "done")

    updated_doc = Map.put(state_doc, "extra", true)

    assert {:ok, %{latest_state: ^updated_doc}} =
             Loops.put_state_projection("LOOP-L5", updated_doc)

    assert %{status: "ready", latest_state: ^updated_doc} = Loops.get!("LOOP-L5")
  end

  test "resume/2 on an unknown loop_id is a typed refusal, not a CaseClauseError" do
    assert {:error, :not_found} = Loops.resume("LOOP-UNKNOWN", 3)
  end

  test "resume/2 widens a held loop's budget and clears the hold" do
    {:ok, _} = Loops.create(valid_attrs("LOOP-L6"))
    {:ok, :transitioned} = Loops.set_status("LOOP-L6", "needs_human", "blocked")

    assert {:ok, %{status: "running", max_iterations: 3, stop_reason: nil}} =
             Loops.resume("LOOP-L6", 3)
  end

  test "resume/2 refuses a non-widening budget on a held loop" do
    {:ok, _} = Loops.create(valid_attrs("LOOP-L7"))
    {:ok, :transitioned} = Loops.set_status("LOOP-L7", "needs_human", "blocked")

    assert {:error, :non_widening_budget} = Loops.resume("LOOP-L7", 2)
  end

  test "resume/2 refuses a loop that isn't held" do
    {:ok, _} = Loops.create(valid_attrs("LOOP-L8"))

    assert {:error, :not_held} = Loops.resume("LOOP-L8", 3)
  end
end
