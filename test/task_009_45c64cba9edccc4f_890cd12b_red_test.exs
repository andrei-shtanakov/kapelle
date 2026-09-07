defmodule Kapelle.Task00945c64cba9edccc4f890cd12bRedTest do
  @moduledoc """
  RED test for TASK-009 (spec/real-llm-provider-adapters-20260907-tasks.md,
  DT-09): `test/kapelle/product/live_run_smoke_test.exs` is the sole owner
  of the opt-in live-provider run — a `:live_product_run`-tagged file whose
  `setup_all` refuses immediately, naming the missing `ANTHROPIC_API_KEY`
  env var, before any network call when the key is absent (BEH-26), and
  whose end-to-end example reaches a verdict with a measured `cost.tokens`
  and a report naming the live agent (BEH-27).

  That file does not exist in the repository yet, so neither scenario is
  implemented — this test fails on the file's very existence.
  """

  use ExUnit.Case, async: true

  @owning_file "test/kapelle/product/live_run_smoke_test.exs"

  test "live_run_smoke_test.exs exists and names BEH-26 and BEH-27" do
    assert File.exists?(@owning_file),
           "#{@owning_file} does not exist yet — DT-09's opt-in guard " <>
             "(BEH-26: refuses without a key, naming ANTHROPIC_API_KEY) and " <>
             "its end-to-end live run (BEH-27: verdict with measured " <>
             "cost.tokens) are not implemented"

    source = File.read!(@owning_file)

    missing = Enum.reject(~w(BEH-26 BEH-27), &String.contains?(source, &1))

    assert missing == [],
           "#{@owning_file} does not yet assert #{inspect(missing)} — DT-09's " <>
             "opt-in scenarios are not checked yet"
  end
end
