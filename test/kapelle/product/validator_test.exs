defmodule Kapelle.Product.ValidatorTest do
  use ExUnit.Case, async: true

  alias Kapelle.Product.Contracts
  alias Kapelle.Product.Validator

  test "kinds/0 lists exactly the eight vendored kinds" do
    assert Enum.sort(Contracts.kinds()) ==
             Enum.sort(
               ~w(idea research_pack concept_draft product_proposal exchange_log loop_state gate_decision loop_resume_decision)a
             )
  end

  test "a valid document validates :ok" do
    doc =
      Contracts.dir!(:research_pack)
      |> Path.join("fixtures/valid/rp-001.yaml")
      |> File.read!()
      |> YamlElixir.read_from_string!()

    assert :ok = Validator.validate(:research_pack, doc)
  end

  test "an invalid document is a typed invalid_artifact, never a generic success" do
    assert {:error, {:invalid_artifact, :research_pack, errors}} =
             Validator.validate(:research_pack, %{"id" => "RP-001"})

    assert is_list(errors) and errors != []
  end

  test "an unknown kind is a typed unknown_contract failure" do
    assert {:error, {:unknown_contract, :no_such_kind}} = Validator.validate(:no_such_kind, %{})
  end

  test "a non-map document is a typed unparseable failure" do
    assert {:error, {:unparseable, {:not_a_document, _}}} = Validator.validate(:idea, [1, 2])
  end
end
