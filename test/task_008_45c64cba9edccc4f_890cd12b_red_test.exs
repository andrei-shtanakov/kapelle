defmodule Kapelle.Product.Task008RedTest do
  use ExUnit.Case, async: true

  # BEH-25: the default `mix test` run must exclude the opt-in live
  # provider run tag, the same way `:provider_smoke` is already excluded
  # in test/test_helper.exs — otherwise `mix test` would try to pay for
  # a live provider call by default. Not yet configured, so this fails.
  test "default suite configuration excludes the live product run tag" do
    assert :live_product_run in ExUnit.configuration()[:exclude]
  end
end
