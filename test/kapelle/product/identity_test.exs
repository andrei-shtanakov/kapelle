defmodule Kapelle.Product.IdentityTest do
  use ExUnit.Case, async: true

  alias Kapelle.Product.Identity

  @table %{
    idea: "id",
    research_pack: "id",
    concept_draft: "id",
    exchange_log: "id",
    product_proposal: "proposal_id",
    loop_state: "loop_id",
    gate_decision: "decision_id"
  }

  test "the identity field table covers exactly the seven kinds" do
    for {kind, field} <- @table, do: assert(Identity.field(kind) == field)
  end

  test "of/2 extracts the identity value" do
    assert {:ok, "PP-101"} = Identity.of(:product_proposal, %{"proposal_id" => "PP-101"})
    assert {:ok, "LOOP-101"} = Identity.of(:loop_state, %{"loop_id" => "LOOP-101"})
    assert {:ok, "GD-001"} = Identity.of(:gate_decision, %{"decision_id" => "GD-001"})
    assert {:ok, "RP-001"} = Identity.of(:research_pack, %{"id" => "RP-001"})
  end

  test "a document missing its identity field is a typed failure, not nil" do
    assert {:error, {:missing_identity, :loop_state, "loop_id"}} =
             Identity.of(:loop_state, %{"id" => "not-the-identity"})
  end
end
