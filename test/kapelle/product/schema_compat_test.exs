defmodule Kapelle.Product.SchemaCompatTest do
  use ExUnit.Case, async: true

  test "a 2020-12-declaring schema with draft-7-compatible keywords resolves and validates after $schema strip" do
    schema =
      %{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "object",
        "additionalProperties" => false,
        "required" => ["id"],
        "properties" => %{"id" => %{"type" => "string", "pattern" => "^RP-[0-9]{3,}$"}},
        "$defs" => %{"x" => %{"type" => "integer"}}
      }
      |> Map.delete("$schema")
      |> ExJsonSchema.Schema.resolve()

    assert :ok = ExJsonSchema.Validator.validate(schema, %{"id" => "RP-001"})
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, %{"id" => "nope"})
    assert {:error, _} = ExJsonSchema.Validator.validate(schema, %{"id" => "RP-001", "extra" => 1})
  end
end
