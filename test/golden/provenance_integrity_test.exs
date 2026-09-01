defmodule Kapelle.Golden.ProvenanceIntegrityTest do
  @moduledoc """
  TASK-004 (spec/WS-kapelle-47-tasks.md): the Mix-workflow integration,
  read-only and diagnostic-boundary contract for
  `Kapelle.Golden.ProvenanceIntegrity`, matching the `checked_by` target
  named in `workstreams/WS-kapelle-47/spec/15-behaviour-spec.md`.

  BEH-16's cwd-independence clause and the basic "committed set passes"
  clause are already proven by test/task_001_red_test.exs (positive run on
  `test/support/fixtures/golden`) and the frozen test/task_004_red_test.exs
  (`check/0` resolves its root independently of the process cwd). Both run
  under plain `mix test`, with no env vars, network access or producer
  checkout — the same is true of every test below, by construction rather
  than by assertion.

  This file covers what those do not:

  - BEH-17: a negative run leaves the working tree byte-for-byte unchanged.
  - BEH-18: a manifest produced by the real `scripts/gen_golden.sh`, copied
    unmodified, is accepted without any reformatting.
  - BEH-19: the explicit guarantee boundary — a payload edit whose digest
    was consistently updated in the same change is not, and cannot be,
    flagged by this check. That is documented here as the contracted
    expectation (NFR-02), not chased as a bug.
  """

  use ExUnit.Case, async: true

  alias Kapelle.Golden.ProvenanceIntegrity

  @committed_root "test/support/fixtures/golden"

  @original_payload "original payload\n"
  @original_payload_sha256 "b3090ea8c58632fb10423baf7827446378fd0653b976050cc04eb70fa6053ef3"
  @edited_payload "EDITED payload\n"
  @edited_payload_sha256 "af96d87f4e12416e85131b3c8e20cf685ba750d43fbe9e2db8b6f99bedec633d"

  defp tmp_dir! do
    path =
      Path.join(System.tmp_dir!(), "kapelle_task004_#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp scenario_dir!(root, name) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    dir
  end

  defp write_manifest!(scenario_dir, scenario_name, checksum_lines) do
    body =
      [
        "scenario: #{scenario_name}",
        "producer: test-harness",
        "generated: 2026-08-31" | checksum_lines
      ]
      |> Enum.join("\n")

    File.write!(Path.join(scenario_dir, "PROVENANCE"), body <> "\n")
  end

  # Byte content plus the metadata a silent in-place rewrite would disturb
  # (mode, mtime), for every regular file under `root` — used to prove the
  # check touches nothing (BEH-17).
  defp snapshot!(root) do
    root
    |> walk_regular_files!()
    |> Map.new(fn absolute_path ->
      stat = File.lstat!(absolute_path)
      content = File.read!(absolute_path)
      relative = Path.relative_to(absolute_path, root)
      {relative, {content, stat.mode, stat.mtime}}
    end)
  end

  defp walk_regular_files!(dir) do
    dir
    |> File.ls!()
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.flat_map(fn path ->
      case File.lstat!(path) do
        %File.Stat{type: :directory} -> walk_regular_files!(path)
        %File.Stat{type: :regular} -> [path]
        %File.Stat{} -> []
      end
    end)
  end

  test "a negative run leaves the working tree byte-for-byte unchanged (BEH-17)" do
    root = tmp_dir!()
    scenario = scenario_dir!(root, "scenario")
    payload_path = Path.join(scenario, "payload.txt")
    File.write!(payload_path, @original_payload)
    write_manifest!(scenario, "scenario", ["sha256 ./payload.txt: #{@original_payload_sha256}"])

    # Silent drift: the payload changes underneath an untouched manifest,
    # exactly like BEH-13, so `check/1` is guaranteed to return an error —
    # the negative run the checklist asks the read-only proof to cover.
    File.write!(payload_path, @edited_payload)

    before_snapshot = snapshot!(root)

    assert {:error, violations} = ProvenanceIntegrity.check(root)
    assert Enum.any?(violations, &(&1.class == :checksum_mismatch))

    assert snapshot!(root) == before_snapshot,
           "check/1 must not modify payload, PROVENANCE, or their metadata on a failing run"
  end

  test "a manifest produced by the real scripts/gen_golden.sh is accepted unmodified (BEH-18)" do
    # Actually invoking scripts/gen_golden.sh needs a producer checkout and
    # network access, which BEH-17/FR-08 forbid this suite from doing. The
    # committed `happy` scenario already IS that script's real, unedited
    # output (see its `generator:`/`generator argv:` lines); copying it
    # byte-for-byte into a fresh root and checking it there proves the
    # generator's format is accepted with no reformatting step of any kind,
    # without re-running the generator itself.
    committed_happy = Path.join(@committed_root, "happy")
    assert File.dir?(committed_happy), "expected the committed happy golden scenario to exist"

    root = tmp_dir!()
    copied_happy = Path.join(root, "happy")
    File.cp_r!(committed_happy, copied_happy)

    assert {:ok, ["happy"]} = ProvenanceIntegrity.check(root)
  end

  test "a consistently updated payload+digest edit passes — the documented guarantee boundary (BEH-19)" do
    root = tmp_dir!()
    scenario = scenario_dir!(root, "scenario")
    payload_path = Path.join(scenario, "payload.txt")
    File.write!(payload_path, @original_payload)
    write_manifest!(scenario, "scenario", ["sha256 ./payload.txt: #{@original_payload_sha256}"])

    assert {:ok, _} = ProvenanceIntegrity.check(root)

    # The edit under test: payload bytes change AND the manifest's digest is
    # updated to match, in the same step — as a legitimate `scripts/gen_golden.sh`
    # re-run or a hand-authored fixture update would do.
    File.write!(payload_path, @edited_payload)
    write_manifest!(scenario, "scenario", ["sha256 ./payload.txt: #{@edited_payload_sha256}"])

    # NFR-02: this check only proves internal consistency between a
    # scenario's payload and its own manifest — it is not a signature and
    # cannot, by design, tell a legitimate update from a malicious one that
    # touched both files together. That a consistent edit passes is the
    # contracted boundary, not a gap: trusting the edit itself remains the
    # job of Git diff and code review, never this check.
    assert {:ok, _} = ProvenanceIntegrity.check(root)
  end
end
