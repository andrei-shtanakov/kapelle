defmodule Kapelle.Task004RedTest do
  @moduledoc """
  RED test for TASK-004 (spec/WS-kapelle-47-tasks.md): the not-yet-existing
  `Kapelle.Golden.ProvenanceIntegrity.check/0` — the zero-arg entry point a
  supported Mix workflow calls, which must resolve the project's own golden
  root independently of the OS process's current working directory
  (workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-16, FR-07:
  "должна быть ... независимой от текущего рабочего каталога процесса при
  запуске из поддерживаемого Mix workflow").

  `check/1` (TASK-001..003) only proves the scenario-walking and
  byte-verification contract given an explicit root handed to it by the
  caller; it says nothing about how that root is found when the process cwd
  is not the repo root, which is exactly the gap BEH-16's second clause
  targets. This mirrors the cwd-independence idiom already used for schema
  loading in test/kapelle/product/schema_cwd_independence_test.exs: change
  the OS cwd away from the repo root and prove the lookup still succeeds,
  rather than trusting a cwd-relative literal.
  """

  use ExUnit.Case, async: false

  alias Kapelle.Golden.ProvenanceIntegrity

  test "check/0 finds the project's own golden root and passes even when the process cwd is elsewhere" do
    tmp = System.tmp_dir!()
    old = File.cwd!()

    try do
      File.cd!(tmp)

      assert {:ok, scenarios} = ProvenanceIntegrity.check()

      assert Enum.sort(scenarios) == [
               "happy",
               "invalid_artifact",
               "needs_human",
               "resume"
             ]
    after
      File.cd!(old)
    end
  end
end
