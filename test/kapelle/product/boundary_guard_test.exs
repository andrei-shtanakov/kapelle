defmodule Kapelle.Product.BoundaryGuardTest do
  use ExUnit.Case, async: true

  @forbidden [
    ~r/\.\.\/impresario/,
    ~r/_cowork_output/,
    ~r/labs\/(all_ai_orchestrators\/)?impresario/
  ]

  test "no runtime module references the impresario checkout or _cowork_output" do
    offenders =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        source = File.read!(path)
        Enum.any?(@forbidden, &Regex.match?(&1, source))
      end)

    assert offenders == [],
           "runtime files referencing the producer checkout: #{inspect(offenders)}"
  end
end
