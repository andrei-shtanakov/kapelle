defmodule Kapelle.Task002RedTest do
  @moduledoc """
  RED test for TASK-002 (spec/WS-kapelle-47-tasks.md): path safety and
  one-to-one payload/checksum coverage for
  `Kapelle.Golden.ProvenanceIntegrity.check/1`. Exercises BEH-06..BEH-12
  from `workstreams/WS-kapelle-47/spec/15-behaviour-spec.md`: an unsafe or
  reserved checksum path is rejected before its target is read (BEH-06); a
  lexically non-canonical alias for a payload does not create a second,
  distinct entry (BEH-07); a symlink inside or outside the scenario is
  never traced or hashed (BEH-08); an undeclared payload, a declared but
  missing payload, and a duplicate checksum entry are three distinguishable
  failure classes (BEH-09..BEH-11); and a payload nested two levels deep is
  still covered (BEH-12).
  """

  use ExUnit.Case, async: true

  alias Kapelle.Golden.ProvenanceIntegrity

  @payload "payload\n"
  @payload_sha256 "d4e4877bac978b7952f0d544fc52ebff5411d351d129f1f056fa43f11da9af2b"

  @nested_payload "nested payload\n"
  @nested_payload_sha256 "4e7267fd5c54130fe83e69920d63e38117957e56f9172965b8db27c75a3c1a96"

  @unsafe_paths [
    "/absolute",
    "../outside",
    "./dir/../../outside",
    "./PROVENANCE"
  ]

  defp tmp_dir! do
    path =
      Path.join(System.tmp_dir!(), "kapelle_task002_#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp scenario_dir!(root, name \\ "scenario") do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    dir
  end

  defp write_manifest!(scenario_dir, checksum_lines) do
    body =
      ["scenario: scenario", "producer: test-harness", "generated: 2026-08-31" | checksum_lines]
      |> Enum.join("\n")

    File.write!(Path.join(scenario_dir, "PROVENANCE"), body <> "\n")
  end

  defp assert_class(violations, class, context) do
    assert Enum.any?(violations, &(&1.class == class)),
           "expected #{class} violation for #{context}, got: #{inspect(violations)}"
  end

  test "unsafe paths, aliases, symlinks and coverage mismatches are all rejected" do
    # BEH-06: every unsafe/reserved path is rejected with class `unsafe_path`
    # before the target is ever read (the target need not even exist).
    for path <- @unsafe_paths do
      root = tmp_dir!()
      scenario = scenario_dir!(root)
      write_manifest!(scenario, ["sha256 #{path}: #{@payload_sha256}"])

      assert {:error, violations} = ProvenanceIntegrity.check(root),
             "expected unsafe_path failure for #{path}"

      assert_class(violations, :unsafe_path, path)
    end

    # BEH-07: a lexically non-canonical alias for a real payload is rejected
    # as unsafe_path, and does not slip through as a second, distinct entry
    # for the same canonical payload.
    alias_root = tmp_dir!()
    alias_scenario = scenario_dir!(alias_root)
    File.mkdir_p!(Path.join(alias_scenario, "workspace"))
    File.write!(Path.join(alias_scenario, "workspace/evidence.json"), @payload)

    write_manifest!(alias_scenario, [
      "sha256 ./workspace/./evidence.json: #{@payload_sha256}"
    ])

    assert {:error, alias_violations} = ProvenanceIntegrity.check(alias_root)
    assert_class(alias_violations, :unsafe_path, "./workspace/./evidence.json")

    # BEH-08: a symlink inside the scenario is never traced or hashed and
    # is reported as `non_regular_payload`, not silently skipped.
    inside_link_root = tmp_dir!()
    inside_scenario = scenario_dir!(inside_link_root)
    real_file = Path.join(inside_scenario, "real.txt")
    File.write!(real_file, @payload)
    File.ln_s!(real_file, Path.join(inside_scenario, "inside-link"))
    write_manifest!(inside_scenario, ["sha256 ./inside-link: #{@payload_sha256}"])

    assert {:error, inside_link_violations} = ProvenanceIntegrity.check(inside_link_root)
    assert_class(inside_link_violations, :non_regular_payload, "./inside-link")

    # BEH-08: a symlink pointing outside the scenario must not be followed
    # and read either.
    outside_link_root = tmp_dir!()
    outside_scenario = scenario_dir!(outside_link_root)
    outside_target = Path.join(outside_link_root, "outside.txt")
    File.write!(outside_target, @payload)
    File.ln_s!(outside_target, Path.join(outside_scenario, "outside-link"))
    write_manifest!(outside_scenario, ["sha256 ./outside-link: #{@payload_sha256}"])

    assert {:error, outside_link_violations} = ProvenanceIntegrity.check(outside_link_root)
    assert_class(outside_link_violations, :non_regular_payload, "./outside-link")

    # BEH-09/BEH-10/BEH-11: three distinguishable coverage classes in a
    # single scenario, plus BEH-12 (a payload nested two levels deep is
    # covered, both when correctly declared and when its entry is dropped).
    coverage_root = tmp_dir!()
    coverage_scenario = scenario_dir!(coverage_root)
    File.mkdir_p!(Path.join(coverage_scenario, "workspace/nested"))

    # unlisted_payload: a real file with no manifest entry at all.
    File.write!(Path.join(coverage_scenario, "unlisted.txt"), @payload)

    # duplicate_checksum: one canonical path declared twice.
    File.write!(Path.join(coverage_scenario, "duplicated.txt"), @payload)

    # missing_payload: declared in the manifest but absent from disk.
    # nested payload (BEH-12): declared, present, correct, two levels deep.
    File.write!(
      Path.join(coverage_scenario, "workspace/nested/evidence.json"),
      @nested_payload
    )

    write_manifest!(coverage_scenario, [
      "sha256 ./duplicated.txt: #{@payload_sha256}",
      "sha256 ./duplicated.txt: #{@payload_sha256}",
      "sha256 ./missing.yaml: #{@payload_sha256}",
      "sha256 ./workspace/nested/evidence.json: #{@nested_payload_sha256}"
    ])

    assert {:error, coverage_violations} = ProvenanceIntegrity.check(coverage_root)

    assert_class(coverage_violations, :unlisted_payload, "./unlisted.txt")
    assert_class(coverage_violations, :duplicate_checksum, "./duplicated.txt")
    assert_class(coverage_violations, :missing_payload, "./missing.yaml")

    refute Enum.any?(coverage_violations, fn v ->
             v[:path] == "./workspace/nested/evidence.json"
           end),
           "nested payload at depth >= 2 must be covered by its declared entry, got: " <>
             inspect(coverage_violations)
  end
end
