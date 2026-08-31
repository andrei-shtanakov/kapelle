defmodule Kapelle.Task003ChecksumCoverageTest do
  @moduledoc """
  Follow-up coverage for TASK-003 (spec/WS-kapelle-47-tasks.md): the
  `unreadable_payload` class produced by
  `Kapelle.Golden.ProvenanceIntegrity.check/1` when a declared payload
  exists as a regular file (so it passes the earlier existence checks) but
  can no longer be read at checksum time. This complements
  test/task_003_red_test.exs (frozen), which only exercises the
  `checksum_mismatch` branch.
  """

  use ExUnit.Case, async: true

  alias Kapelle.Golden.ProvenanceIntegrity

  @payload "payload\n"
  @payload_sha256 "d4e4877bac978b7952f0d544fc52ebff5411d351d129f1f056fa43f11da9af2b"

  defp tmp_dir! do
    path =
      Path.join(System.tmp_dir!(), "kapelle_task003_cov_#{System.unique_integer([:positive])}")

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

  @tag :unreadable_payload
  test "a declared payload that becomes unreadable is unreadable_payload, not checksum_mismatch" do
    root = tmp_dir!()
    scenario = scenario_dir!(root)
    payload_path = Path.join(scenario, "payload.txt")
    File.write!(payload_path, @payload)
    write_manifest!(scenario, ["sha256 ./payload.txt: #{@payload_sha256}"])

    File.chmod!(payload_path, 0o000)
    on_exit(fn -> File.chmod!(payload_path, 0o644) end)

    assert {:error, violations} = ProvenanceIntegrity.check(root)

    assert Enum.any?(violations, fn v ->
             v.class == :unreadable_payload and v.scenario == "scenario" and
               v.path == "./payload.txt"
           end),
           "expected unreadable_payload naming scenario and path, got: " <> inspect(violations)

    refute Enum.any?(violations, &(&1.class == :checksum_mismatch)),
           "an unreadable payload must not also be reported as checksum_mismatch, got: " <>
             inspect(violations)
  end
end
