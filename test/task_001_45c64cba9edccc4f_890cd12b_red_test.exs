defmodule Kapelle.Product.AgentResolveRedTest do
  @moduledoc """
  RED phase for TASK-001 (DT-01): `Kapelle.Product.Agent.resolve/1` must be
  total — `{:ok, {module, key}} | {:error, reason}` — and never raise on an
  unrecognized scheme (BEH-03). Only `resolve!/1` exists today.
  """

  use ExUnit.Case, async: true

  alias Kapelle.Product.Agent

  test "resolve/1 returns a named unknown_scheme error instead of raising" do
    assert {:error, {:unknown_scheme, "provider:gpt-5"}} = Agent.resolve("provider:gpt-5")
  end
end
