defmodule Kapelle.Contracts.VendoredImpresarioTest do
  use ExUnit.Case, async: true

  @vendor_root Path.join(File.cwd!(), "priv/contracts/impresario")
  @expected_kinds ~w(idea research-pack concept-draft product-proposal exchange-log loop-state gate-decision loop-resume-decision)

  defp pins do
    Path.wildcard(Path.join(@vendor_root, "*/v1/PIN"))
  end

  defp parse_pin(pin_path) do
    lines = pin_path |> File.read!() |> String.split("\n", trim: true)

    source =
      Enum.find_value(lines, fn line ->
        case Regex.run(~r/^source: impresario@([0-9a-f]{7,40}) (.+)$/, line) do
          [_, sha, path] -> %{producer_commit: sha, producer_path: path}
          nil -> nil
        end
      end)

    hashes =
      for line <- lines,
          [_, rel, hex] <- [Regex.run(~r/^sha256 (.+): ([0-9a-f]{64})$/, line)],
          do: {rel, hex}

    %{source: source, hashes: hashes, dir: Path.dirname(pin_path)}
  end

  test "exactly the eight expected contracts are vendored, each with a PIN" do
    found =
      pins()
      |> Enum.map(&(&1 |> Path.dirname() |> Path.dirname() |> Path.basename()))
      |> Enum.sort()

    assert found == Enum.sort(@expected_kinds)
  end

  test "every vendored file is byte-identical to its PIN hash, and no file is unpinned" do
    for pin <- pins() do
      %{source: source, hashes: hashes, dir: dir} = parse_pin(pin)
      assert source, "#{pin}: missing/invalid source line"
      assert hashes != [], "#{pin}: no sha256 lines"

      for {rel, hex} <- hashes do
        bytes = File.read!(Path.join(dir, rel))
        actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
        assert actual == hex, "#{dir}/#{rel}: vendored bytes differ from PIN"
      end

      on_disk =
        dir
        |> Path.join("**")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(&Path.relative_to(&1, dir))
        |> Enum.reject(&(&1 == "PIN"))
        |> Enum.sort()

      assert on_disk == hashes |> Enum.map(&elem(&1, 0)) |> Enum.sort(),
             "#{dir}: files on disk and files pinned diverge"
    end
  end

  test "anti-mix: every PIN carries the same producer_commit" do
    commits = pins() |> Enum.map(&parse_pin(&1).source.producer_commit) |> Enum.uniq()
    assert length(commits) == 1, "mixed producer commits: #{inspect(commits)}"
  end
end
