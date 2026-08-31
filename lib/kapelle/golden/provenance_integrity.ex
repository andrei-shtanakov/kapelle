defmodule Kapelle.Golden.ProvenanceIntegrity do
  @moduledoc """
  Fail-closed integrity check for golden-fixture scenarios.

  Discovers scenario directories under a golden root by walking the
  filesystem (no name allowlist, workstreams/WS-kapelle-47 BEH-01/BEH-02) and
  parses each scenario's `PROVENANCE` manifest fail-closed: any inability to
  prove the manifest is a readable, well-formed checksum table is a failure,
  never a vacuous success (BEH-03..BEH-05). Every checksum path is confined
  to a canonical relative path inside the scenario directory before its
  target is ever touched, symlinks are never traced or hashed, and the set
  of on-disk payload files must correspond one-to-one with declared checksum
  entries (BEH-06..BEH-12). Byte-for-byte checksum verification against
  payload files is out of scope here and is covered by later checks in the
  same integrity pipeline.
  """

  @manifest_name "PROVENANCE"
  @reserved_manifest_path "./" <> @manifest_name

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
      {:ok, entries} -> Enum.filter(entries, &scenario_dir?(Path.join(root, &1)))
      {:error, _reason} -> []
    end
  end

  defp scenario_dir?(path) do
    match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))
  end

  defp check_scenario(root, scenario) do
    manifest_path = Path.join([root, scenario, @manifest_name])

    case manifest_state(manifest_path) do
      {:error, class} ->
        [%{class: class, scenario: scenario, path: @manifest_name}]

      {:ok, content} ->
        lines =
          content
          |> String.split("\n")
          |> Enum.reject(&(&1 == ""))

        {entries, malformed_violations} = parse_lines(scenario, lines)

        malformed_violations ++ check_coverage(root, scenario, entries)
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

  defp parse_lines(scenario, lines) do
    {entries, violations} =
      Enum.reduce(lines, {[], []}, fn line, {entries, violations} ->
        cond do
          generator_line?(line) ->
            {entries, violations}

          Regex.match?(@checksum_line, line) ->
            [_, path, digest] = Regex.run(@checksum_line, line)
            {[{path, digest} | entries], violations}

          true ->
            violation = %{class: :malformed_checksum, scenario: scenario, line: line}
            {entries, [violation | violations]}
        end
      end)

    {Enum.reverse(entries), Enum.reverse(violations)}
  end

  defp generator_line?(line) do
    Enum.any?(@generator_line_prefixes, &String.starts_with?(line, &1))
  end

  # Path safety (BEH-06/BEH-07) and one-to-one payload coverage
  # (BEH-08..BEH-12).

  defp check_coverage(root, scenario, entries) do
    scenario_dir = Path.join(root, scenario)

    {safe_entries, unsafe_violations} = classify_paths(scenario, entries)
    declared = Enum.group_by(safe_entries, fn {path, _digest} -> path end)
    declared_paths = MapSet.new(Map.keys(declared))

    duplicate_violations =
      for {path, group} <- declared, length(group) > 1 do
        %{class: :duplicate_checksum, scenario: scenario, path: path}
      end

    existence_violations =
      declared
      |> Map.keys()
      |> Enum.map(&payload_state(scenario_dir, &1))
      |> Enum.reject(&(&1 == nil))
      |> Enum.map(fn {class, path} -> %{class: class, scenario: scenario, path: path} end)

    discovery_violations = discover_violations(scenario_dir, declared_paths, scenario)

    unsafe_violations ++
      duplicate_violations ++ existence_violations ++ discovery_violations
  end

  defp classify_paths(scenario, entries) do
    {safe, violations} =
      Enum.reduce(entries, {[], []}, fn {path, _digest} = entry, {safe, violations} ->
        case path_safety(path) do
          :ok ->
            {[entry | safe], violations}

          :unsafe ->
            violation = %{class: :unsafe_path, scenario: scenario, path: path}
            {safe, [violation | violations]}
        end
      end)

    {Enum.reverse(safe), Enum.reverse(violations)}
  end

  defp path_safety(path) do
    if String.starts_with?(path, "/") do
      :unsafe
    else
      case canonical_segments(path) do
        :escape ->
          :unsafe

        {:ok, []} ->
          :unsafe

        {:ok, segments} ->
          canonical_safety(path, "./" <> Enum.join(segments, "/"))
      end
    end
  end

  defp canonical_safety(path, canonical)
       when canonical == path and canonical != @reserved_manifest_path,
       do: :ok

  defp canonical_safety(_path, _canonical), do: :unsafe

  defp canonical_segments(path) do
    path
    |> Path.split()
    |> Enum.reject(&(&1 == "."))
    |> Enum.reduce_while({:ok, []}, fn
      "..", {:ok, []} -> {:halt, :escape}
      "..", {:ok, [_ | rest]} -> {:cont, {:ok, rest}}
      segment, {:ok, acc} -> {:cont, {:ok, [segment | acc]}}
    end)
    |> case do
      :escape -> :escape
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
    end
  end

  defp payload_state(scenario_dir, canonical_path) do
    absolute_path = Path.join(scenario_dir, String.trim_leading(canonical_path, "./"))

    case File.lstat(absolute_path) do
      {:error, :enoent} -> {:missing_payload, canonical_path}
      {:ok, %File.Stat{type: :regular}} -> nil
      {:ok, %File.Stat{}} -> {:non_regular_payload, canonical_path}
      {:error, _reason} -> {:missing_payload, canonical_path}
    end
  end

  defp discover_violations(scenario_dir, declared_paths, scenario) do
    scenario_dir
    |> discover_entries(scenario_dir)
    |> Enum.reject(fn {_kind, path} ->
      path == @reserved_manifest_path or MapSet.member?(declared_paths, path)
    end)
    |> Enum.map(fn
      {:regular, path} -> %{class: :unlisted_payload, scenario: scenario, path: path}
      {:non_regular, path} -> %{class: :non_regular_payload, scenario: scenario, path: path}
    end)
  end

  defp discover_entries(scenario_dir, dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.flat_map(&classify_entry(scenario_dir, &1))

      {:error, _reason} ->
        []
    end
  end

  defp classify_entry(scenario_dir, absolute_path) do
    case File.lstat(absolute_path) do
      {:ok, %File.Stat{type: :directory}} ->
        discover_entries(scenario_dir, absolute_path)

      {:ok, %File.Stat{type: :regular}} ->
        [{:regular, relative_canonical(scenario_dir, absolute_path)}]

      {:ok, %File.Stat{}} ->
        [{:non_regular, relative_canonical(scenario_dir, absolute_path)}]

      {:error, _reason} ->
        []
    end
  end

  defp relative_canonical(scenario_dir, absolute_path) do
    "./" <> Path.relative_to(absolute_path, scenario_dir)
  end
end
