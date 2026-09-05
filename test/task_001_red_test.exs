defmodule Kapelle.Task001RedTest do
  @moduledoc """
  RED test for TASK-001 (spec/WS-kapelle-47-tasks.md): the not-yet-existing
  `Kapelle.Golden.ProvenanceIntegrity.check/1` that discovers golden-fixture
  scenarios by walking the filesystem (no name allowlist) and parses each
  scenario's `PROVENANCE` manifest fail-closed. Exercises BEH-01..BEH-05 from
  `workstreams/WS-kapelle-47/spec/15-behaviour-spec.md`: the committed set
  (`happy`, `needs_human`, `resume`, `invalid_artifact`) is discovered and
  passes untouched; a scenario dropped into a temp root under an unlisted
  name is discovered automatically; an empty golden root fails with
  `no_scenarios`; every disallowed `PROVENANCE` state (missing, empty,
  directory, symlink, unreadable) fails with its own class; and every
  malformed checksum-line shape fails with `malformed_checksum`.
  """

  use ExUnit.Case, async: true

  alias Kapelle.Golden.ProvenanceIntegrity

  @committed_root "test/support/fixtures/golden"
  @future_payload "future payload\n"
  @future_payload_sha256 "90269a722908025e2828db3b545c9db91cc35fc8f8cd4d02f3d24aa0f61f6383"

  @manifest_states [
    {:missing, :manifest_missing},
    {:empty, :manifest_invalid},
    {:directory, :manifest_not_regular},
    {:symlink, :manifest_not_regular},
    {:unreadable, :manifest_unreadable}
  ]

  @malformed_checksum_lines [
    "md5 ./payload: 00000000000000000000000000000000",
    "sha256 : aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "sha256 ./payload aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "sha256 ./payload: abc123",
    "sha256 ./payload: zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
  ]

  defp tmp_dir! do
    path =
      Path.join(System.tmp_dir!(), "kapelle_task001_#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp write_future_case!(root) do
    scenario_dir = Path.join(root, "future_case")
    File.mkdir_p!(scenario_dir)
    File.write!(Path.join(scenario_dir, "payload.txt"), @future_payload)

    File.write!(Path.join(scenario_dir, "PROVENANCE"), """
    scenario: future_case
    producer: test-harness
    generated: 2026-08-31
    sha256 ./payload.txt: #{@future_payload_sha256}
    """)
  end

  defp write_broken_manifest!(root, :missing) do
    File.mkdir_p!(Path.join(root, "broken"))
  end

  defp write_broken_manifest!(root, :empty) do
    scenario_dir = Path.join(root, "broken")
    File.mkdir_p!(scenario_dir)
    File.write!(Path.join(scenario_dir, "PROVENANCE"), "")
  end

  defp write_broken_manifest!(root, :directory) do
    scenario_dir = Path.join(root, "broken")
    File.mkdir_p!(scenario_dir)
    File.mkdir_p!(Path.join(scenario_dir, "PROVENANCE"))
  end

  defp write_broken_manifest!(root, :symlink) do
    scenario_dir = Path.join(root, "broken")
    File.mkdir_p!(scenario_dir)
    target = Path.join(scenario_dir, "target.txt")
    File.write!(target, "elsewhere")
    File.ln_s!(target, Path.join(scenario_dir, "PROVENANCE"))
  end

  defp write_broken_manifest!(root, :unreadable) do
    scenario_dir = Path.join(root, "broken")
    File.mkdir_p!(scenario_dir)
    provenance_path = Path.join(scenario_dir, "PROVENANCE")
    File.write!(provenance_path, "scenario: broken\n")
    File.chmod!(provenance_path, 0o000)
    on_exit(fn -> File.chmod!(provenance_path, 0o644) end)
  end

  defp write_malformed_checksum_manifest!(root, line) do
    scenario_dir = Path.join(root, "broken")
    File.mkdir_p!(scenario_dir)

    File.write!(Path.join(scenario_dir, "PROVENANCE"), """
    scenario: broken
    producer: test-harness
    generated: 2026-08-31
    #{line}
    """)
  end

  test "committed golden set is discovered and passes; empty/invalid/malformed manifests fail closed with the right class" do
    # BEH-01: the five committed scenarios are discovered from disk and the
    # unchanged committed set passes with no files touched.
    assert {:ok, scenarios} = ProvenanceIntegrity.check(@committed_root)

    assert Enum.sort(scenarios) == [
             "happy",
             "human_waiver",
             "invalid_artifact",
             "needs_human",
             "resume"
           ]

    # BEH-02: a scenario under an unlisted name, dropped into the golden
    # root at test time, is picked up by discovery without any code change.
    discovery_root = tmp_dir!()
    File.cp_r!(@committed_root, discovery_root)
    write_future_case!(discovery_root)

    assert {:ok, scenarios_with_future} = ProvenanceIntegrity.check(discovery_root)

    assert Enum.sort(scenarios_with_future) == [
             "future_case",
             "happy",
             "human_waiver",
             "invalid_artifact",
             "needs_human",
             "resume"
           ]

    # BEH-03: an empty golden root is a failure naming the root, not a
    # vacuous success.
    empty_root = tmp_dir!()
    assert {:error, empty_violations} = ProvenanceIntegrity.check(empty_root)

    assert Enum.any?(empty_violations, fn v ->
             v.class == :no_scenarios and v.root == empty_root
           end)

    # BEH-04: every disallowed PROVENANCE state fails with its own class.
    for {state, expected_class} <- @manifest_states do
      root = tmp_dir!()
      write_broken_manifest!(root, state)

      assert {:error, violations} = ProvenanceIntegrity.check(root),
             "expected failure for PROVENANCE state #{state}"

      assert Enum.any?(violations, fn v ->
               v.class == expected_class and v.scenario == "broken" and v.path == "PROVENANCE"
             end),
             "expected #{expected_class} for PROVENANCE state #{state}, got: #{inspect(violations)}"
    end

    # BEH-05: every malformed checksum-line shape fails with
    # malformed_checksum, naming the offending line.
    for line <- @malformed_checksum_lines do
      root = tmp_dir!()
      write_malformed_checksum_manifest!(root, line)

      assert {:error, violations} = ProvenanceIntegrity.check(root),
             "expected failure for malformed checksum line: #{line}"

      assert Enum.any?(violations, fn v ->
               v.class == :malformed_checksum and v.scenario == "broken" and v.line == line
             end),
             "expected malformed_checksum for line #{inspect(line)}, got: #{inspect(violations)}"
    end
  end
end
