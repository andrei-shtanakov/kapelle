defmodule Kapelle.Task006RedTest do
  @moduledoc """
  RED test for TASK-006 (spec/real-llm-provider-adapters-20260907-tasks.md,
  DT-06, BEH-02/BEH-07/BEH-31): `test/kapelle/product/boundary_guard_test.exs`
  is the sole owner of these three boundary invariants — address-prefix
  parsing confined to `Kapelle.Product.Agent` (BEH-02), no second
  model-addressing mechanism duplicating the catalog (BEH-07), and the m1
  execution plane (`Executor.Adapter`, `Executor.ChainAdapter`,
  `FallbackResolver`, the artifact contract/normalizer) left untouched
  (BEH-31).

  Today that file only carries the pre-existing impresario/`_cowork_output`
  checkout guard (see its current source): none of the three BEH ids this
  task owns are named or asserted anywhere in it yet, so the group this
  task is responsible for cannot be called green.
  """

  use ExUnit.Case, async: true

  @owning_file "test/kapelle/product/boundary_guard_test.exs"

  test "boundary_guard_test.exs names and asserts BEH-02, BEH-07 and BEH-31" do
    source = File.read!(@owning_file)

    missing = Enum.reject(~w(BEH-02 BEH-07 BEH-31), &String.contains?(source, &1))

    assert missing == [],
           "#{@owning_file} does not yet assert #{inspect(missing)} — DT-06's " <>
             "boundary invariants (address-prefix parsing confined to " <>
             "Kapelle.Product.Agent, no second model catalog, m1 plane " <>
             "untouched) are not checked yet"
  end
end
