defmodule Kapelle.Task01045c64cba9edccc4f890cd12bRedTest do
  @moduledoc """
  RED test for TASK-010 (spec/real-llm-provider-adapters-20260907-tasks.md,
  DT-10): `docs/live-provider-run.md` is the sole owner of BEH-28 — the
  written instruction that lets an owner with only a repository clone and a
  provider key reproduce DT-09's live run (BEH-27) without asking the
  author anything. Per the design's red-design boundaries, the file's mere
  existence is not the evidence for BEH-28 itself (that example is
  `kind: manual`) — but the file has to actually state the four facts the
  scenario requires: the run command, the required environment variable,
  the agent address form, and where to read the result.

  That file does not exist in the repository yet, so none of the four
  facts are written down — this test fails on the file's very existence.
  """

  use ExUnit.Case, async: true

  @owning_file "docs/live-provider-run.md"

  test "live-provider-run.md exists and states the four BEH-28 facts" do
    assert File.exists?(@owning_file),
           "#{@owning_file} does not exist yet — DT-10's reproduction " <>
             "instruction for BEH-28 (run command, required env var, " <>
             "agent address form, where to read the result) is not written"

    source = File.read!(@owning_file)

    required = [
      "mix test --include live_product_run test/kapelle/product/live_run_smoke_test.exs",
      "ANTHROPIC_API_KEY",
      "model:anthropic@",
      "mix kapelle.product.report"
    ]

    missing = Enum.reject(required, &String.contains?(source, &1))

    assert missing == [],
           "#{@owning_file} does not yet state #{inspect(missing)} — BEH-28's " <>
             "reproduction instruction is incomplete"
  end
end
