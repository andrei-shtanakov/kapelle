defmodule Kapelle.Executor.ResultTest do
  use ExUnit.Case, async: true

  alias Kapelle.Executor.Result

  @valid_attrs %{task_id: "task-1", status: :pass}

  test "new!/1 builds a Result with defaults for optional fields" do
    assert %Result{
             task_id: "task-1",
             status: :pass,
             output: nil,
             duration_ms: nil,
             artifacts: []
           } = Result.new!(@valid_attrs)
  end

  for status <- [:pass, :fail, :error] do
    test "new!/1 accepts status #{inspect(status)}" do
      assert %Result{status: unquote(status)} =
               Result.new!(%{task_id: "task-1", status: unquote(status)})
    end
  end

  test "new!/1 keeps given optional field values" do
    attrs =
      Map.merge(@valid_attrs, %{
        output: "some output",
        duration_ms: 1234,
        artifacts: ["path/to/file"]
      })

    assert %Result{output: "some output", duration_ms: 1234, artifacts: ["path/to/file"]} =
             Result.new!(attrs)
  end

  test "new!/1 raises when a required key is missing" do
    attrs = Map.delete(@valid_attrs, :status)

    assert_raise ArgumentError, fn -> Result.new!(attrs) end
  end

  test "new!/1 raises for an unknown status" do
    attrs = Map.put(@valid_attrs, :status, :unknown)

    assert_raise ArgumentError, fn -> Result.new!(attrs) end
  end

  test "new!/1 raises ArgumentError (not KeyError) for an unknown attrs key" do
    attrs = Map.put(@valid_attrs, :bogus, "value")

    assert_raise ArgumentError, fn -> Result.new!(attrs) end
  end

  test "new!/1 raises when artifacts is not a list" do
    for bad <- [nil, %{}, "artifact", 42] do
      attrs = Map.put(@valid_attrs, :artifacts, bad)

      assert_raise ArgumentError, fn -> Result.new!(attrs) end
    end
  end
end
