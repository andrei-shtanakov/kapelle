defmodule Kapelle.Golden.ProvenanceIntegrity do
  @moduledoc """
  Fail-closed integrity check for golden-fixture scenarios.

  Discovers scenario directories under a golden root by walking the
  filesystem (no name allowlist, workstreams/WS-kapelle-47 BEH-01/BEH-02) and
  parses each scenario's `PROVENANCE` manifest fail-closed: any inability to
  prove the manifest is a readable, well-formed checksum table is a failure,
  never a vacuous success (BEH-03..BEH-05). Path safety and byte-for-byte
  checksum verification against payload files are out of scope here and are
  covered by later checks in the same integrity pipeline.
  """

  @manifest_name "PROVENANCE"

  @generator_line_prefixes [
    "scenario:",
    "producer:",
    "generated:",
    "generator argv:",
    "generator sha256:",
    "generator:",
    "normalizer:"
  ]

  @checksum_line ~r/^sha256 (\S+): ([0-9a-f]{64})$/

  @type violation :: %{optional(atom()) => term()}

  @spec check(String.t()) :: {:ok, [String.t()]} | {:error, [violation()]}
  def check(root) do
    case scenario_names(root) do
      [] ->
        {:error, [%{class: :no_scenarios, root: root}]}

      scenarios ->
        violations = Enum.flat_map(scenarios, &check_scenario(root, &1))

        if violations == [] do
          {:ok, scenarios}
        else
          {:error, violations}
        end
    end
  end

  defp scenario_names(root) do
    case File.ls(root) do
      {:ok, entries} -> Enum.filter(entries, &File.dir?(Path.join(root, &1)))
      {:error, _reason} -> []
    end
  end

  defp check_scenario(root, scenario) do
    manifest_path = Path.join([root, scenario, @manifest_name])

    case manifest_state(manifest_path) do
      {:error, class} ->
        [%{class: class, scenario: scenario, path: @manifest_name}]

      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> Enum.flat_map(&check_line(scenario, &1))
    end
  end

  defp manifest_state(manifest_path) do
    case File.lstat(manifest_path) do
      {:error, :enoent} ->
        {:error, :manifest_missing}

      {:ok, %File.Stat{type: :regular}} ->
        read_manifest(manifest_path)

      {:ok, %File.Stat{}} ->
        {:error, :manifest_not_regular}

      {:error, _reason} ->
        {:error, :manifest_missing}
    end
  end

  defp read_manifest(manifest_path) do
    case File.read(manifest_path) do
      {:ok, ""} -> {:error, :manifest_invalid}
      {:ok, content} -> {:ok, content}
      {:error, _reason} -> {:error, :manifest_unreadable}
    end
  end

  defp check_line(scenario, line) do
    if generator_line?(line) or Regex.match?(@checksum_line, line) do
      []
    else
      [%{class: :malformed_checksum, scenario: scenario, line: line}]
    end
  end

  defp generator_line?(line) do
    Enum.any?(@generator_line_prefixes, &String.starts_with?(line, &1))
  end
end
