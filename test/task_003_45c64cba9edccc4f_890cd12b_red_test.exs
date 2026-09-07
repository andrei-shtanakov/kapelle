defmodule Kapelle.Task00345c64cba9edccc4f890cd12bRedTest do
  @moduledoc """
  RED test for TASK-003 (DT-03): BEH-05 — offline preflight of a `model:`
  catalog id distinguishes `model_not_in_catalog` from the other three
  live-scheme failure reasons, before any outbound network call.

  `Kapelle.Product.Agent.resolve/1` (the port) already accepts any
  syntactically valid `model:<provider>@<model>` address; catalog
  validation is the adapter's job (design §"Формы инвокаций"). So the
  only public entry point the `Kapelle.Product.Agent` behaviour promises
  for this is `produce/3` on the live adapter, `Kapelle.Product.LiveAgent`
  — a module that does not exist yet.
  """

  use ExUnit.Case, async: true

  test "produce/3 rejects a catalog id absent from the catalog as model_not_in_catalog, before any network call" do
    catalog_id = "anthropic@does-not-exist-in-catalog"

    assert {:error, {:model_not_in_catalog, ^catalog_id}} =
             Kapelle.Product.LiveAgent.produce(:researcher, 0, %{key: catalog_id})
  end
end
