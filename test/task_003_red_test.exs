defmodule Kapelle.Task003RedTest do
  @moduledoc """
  RED test for TASK-003 (spec/WS-kapelle-47-tasks.md): byte-exact SHA-256
  verification for `Kapelle.Golden.ProvenanceIntegrity.check/1`. Exercises
  BEH-13..BEH-15 from
  `workstreams/WS-kapelle-47/spec/15-behaviour-spec.md`: a silent single-byte
  edit to a payload, with the manifest left untouched, fails as
  `checksum_mismatch` naming the scenario and relative path (BEH-13); a
  payload rewritten to a semantically equivalent but byte-different JSON
  document fails the same way rather than being normalized away (BEH-14);
  and two independent checksum_mismatch violations in two different
  scenarios are both reported by a single run, in deterministic order
  (BEH-15).
  """

  use ExUnit.Case, async: true

  alias Kapelle.Golden.ProvenanceIntegrity

  @payload_sha256 "d4e4877bac978b7952f0d544fc52ebff5411d351d129f1f056fa43f11da9af2b"
  @compact_json_sha256 "e8d38819d39f705646bfb643368eca78f7db476c16471dbc33b941b27326410d"
  @alpha_payload_sha256 "ef425ec96caf3d79b288aac22ef5ca0097393213d09be9bd947df1758334fe64"
  @beta_payload_sha256 "2ed18965886676eca457cfd0cccf012b6a70c65065bfa438f7ad203b9b5ec063"

  defp tmp_dir! do
    path =
      Path.join(System.tmp_dir!(), "kapelle_task003_#{System.unique_integer([:positive])}")

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

  test "byte-level payload edits are checksum_mismatch, not normalized away, and multiple mismatches are all reported" do
    # BEH-13: manifest matches the original payload; a single byte is then
    # flipped in the payload without touching the manifest. The digest on
    # disk no longer matches the declared one, so this must fail closed as
    # checksum_mismatch naming the scenario and the relative path — not pass
    # because the file still exists and is a regular file.
    byte_edit_root = tmp_dir!()
    byte_edit_scenario = scenario_dir!(byte_edit_root, "byte_edit")
    payload_path = Path.join(byte_edit_scenario, "payload.txt")
    File.write!(payload_path, "payload\n")
    write_manifest!(byte_edit_scenario, "byte_edit", ["sha256 ./payload.txt: #{@payload_sha256}"])

    # Flip one byte in place; the manifest still declares the digest of the
    # original content.
    File.write!(payload_path, "Payload\n")

    assert {:error, byte_edit_violations} = ProvenanceIntegrity.check(byte_edit_root)

    assert Enum.any?(byte_edit_violations, fn v ->
             v.class == :checksum_mismatch and v.scenario == "byte_edit" and
               v.path == "./payload.txt"
           end),
           "expected checksum_mismatch for a single flipped byte, got: " <>
             inspect(byte_edit_violations)

    # BEH-14: the manifest declares the digest of the compact JSON. On disk
    # the payload is replaced by a semantically equivalent but byte-different
    # pretty-printed rendering of the same JSON. Bytes differ, so this must
    # still fail as checksum_mismatch — the check never normalizes JSON,
    # YAML or JSONL content before hashing.
    json_root = tmp_dir!()
    json_scenario = scenario_dir!(json_root, "json_reformat")
    json_path = Path.join(json_scenario, "evidence.json")
    File.write!(json_path, ~s({"a":1,"b":2}\n))

    write_manifest!(json_scenario, "json_reformat", [
      "sha256 ./evidence.json: #{@compact_json_sha256}"
    ])

    File.write!(json_path, "{\n  \"a\": 1,\n  \"b\": 2\n}\n")

    assert {:error, json_violations} = ProvenanceIntegrity.check(json_root)

    assert Enum.any?(json_violations, fn v ->
             v.class == :checksum_mismatch and v.scenario == "json_reformat" and
               v.path == "./evidence.json"
           end),
           "expected checksum_mismatch for semantically-equivalent reformatted JSON, got: " <>
             inspect(json_violations)

    # BEH-15: two independent checksum_mismatch violations, in two different
    # scenarios under the same root, must both be visible from a single run,
    # and the order must be deterministic across repeated runs.
    multi_root = tmp_dir!()
    alpha_scenario = scenario_dir!(multi_root, "alpha")
    alpha_payload = Path.join(alpha_scenario, "payload.txt")
    File.write!(alpha_payload, "alpha payload\n")
    write_manifest!(alpha_scenario, "alpha", ["sha256 ./payload.txt: #{@alpha_payload_sha256}"])
    File.write!(alpha_payload, "Alpha payload\n")

    beta_scenario = scenario_dir!(multi_root, "beta")
    beta_payload = Path.join(beta_scenario, "payload.txt")
    File.write!(beta_payload, "beta payload\n")
    write_manifest!(beta_scenario, "beta", ["sha256 ./payload.txt: #{@beta_payload_sha256}"])
    File.write!(beta_payload, "Beta payload\n")

    assert {:error, first_run} = ProvenanceIntegrity.check(multi_root)
    assert {:error, second_run} = ProvenanceIntegrity.check(multi_root)

    mismatches = fn violations ->
      violations
      |> Enum.filter(&(&1.class == :checksum_mismatch))
      |> Enum.map(&{&1.scenario, &1.path})
    end

    first_mismatches = mismatches.(first_run)
    second_mismatches = mismatches.(second_run)

    assert {"alpha", "./payload.txt"} in first_mismatches
    assert {"beta", "./payload.txt"} in first_mismatches
    assert length(first_mismatches) == 2
    assert first_mismatches == second_mismatches
  end

  test "symlink with matching external digest is a violation, never a hash match" do
    root = tmp_dir!()
    dir = scenario_dir!(root, "scenario")
    outside = Path.join(root, "outside.txt")
    File.write!(outside, "payload\n")
    File.ln_s!(outside, Path.join(dir, "payload.txt"))
    write_manifest!(dir, "scenario", ["sha256 ./payload.txt: #{@payload_sha256}"])

    assert {:error, violations} = ProvenanceIntegrity.check(root)

    assert Enum.any?(
             violations,
             &(&1.class in [:non_regular_payload, :payload_changed_during_check])
           )
  end
end
