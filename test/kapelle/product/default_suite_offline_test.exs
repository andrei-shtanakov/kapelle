defmodule Kapelle.Product.DefaultSuiteOfflineTest do
  @moduledoc """
  BEH-25 (design doc DT-08): the default `mix test` run is offline,
  keyless, and insensitive to provider environment variables.

  This file owns `test/test_helper.exs`'s `:live_product_run` exclusion
  alongside these checks (design doc DT-08) — the two live together
  because the tag exclusion on its own is a configuration, not a proof;
  the proof that the default suite never actually reaches the network is
  below.

  "Over the whole suite run, no attempt reached the network" cannot be
  asserted from an ordinary `test`: ExUnit runs files out of order and
  partly asynchronously, so a test reading a call counter mid-run would
  go green exactly when an offending call happens to fire *after* it —
  proving nothing. Instead we attach a `:telemetry` handler on
  `[:finch, :request, :start]` — the event `Finch.request/3` (and
  `Finch.stream/5`) emits whenever it is actually invoked — the moment
  this module is loaded (i.e. before any test in the suite runs, since
  `mix test` compiles every test file before running any of them), and
  check the accumulated count from `ExUnit.after_suite/1`, which fires
  only once the very last example in the suite has finished.

  `Req.Test` stubs (used throughout `Kapelle.Product.LiveAgentTest` etc.
  via `:product_provider_req_opts`) short-circuit `Req`'s adapter to
  `Req.Plug` before it ever reaches `Req.Finch`/`Finch.request` — so a
  properly stubbed call never fires this event. Only a real, unstubbed
  outgoing request would.
  """

  use ExUnit.Case, async: false

  # Plain local bindings, not module attributes: a closure created in a
  # module's top-level body captures `@attr` reads lazily (resolved
  # against the module's attribute table when the closure *runs*, not
  # when it's defined), which blows up once the module has finished
  # compiling. A local variable is captured by value like any other
  # Elixir closure, which is what both callbacks below need.
  outgoing_attempts_key = {__MODULE__, :outgoing_attempts}
  :persistent_term.put(outgoing_attempts_key, :counters.new(1, []))

  # Detach any handler left over from a previous compile of this module in
  # the same VM (e.g. `mix test.watch`, `recompile()` under `iex -S mix
  # test`) before attaching: the handler id is fixed, so a bare `attach`
  # on a stale id silently fails with `{:error, :already_exists}` and
  # keeps the pre-edit handler running instead of this one.
  handler_id = "kapelle-beh-25-default-suite-offline-guard"
  :telemetry.detach(handler_id)

  :ok =
    :telemetry.attach(
      handler_id,
      [:finch, :request, :start],
      fn _event, _measurements, _metadata, _config ->
        :counters.add(:persistent_term.get(outgoing_attempts_key), 1, 1)
      end,
      nil
    )

  ExUnit.after_suite(fn _stats ->
    attempts = :counters.get(:persistent_term.get(outgoing_attempts_key), 1)

    if attempts > 0 do
      IO.puts(:stderr, """
      BEH-25 violated: the default `mix test` run attempted #{attempts} \
      real outgoing provider call(s) (Finch request start observed) \
      instead of staying fully offline/stubbed.
      """)

      System.halt(1)
    end
  end)

  test "default suite excludes the live product run tag, next to the existing provider smoke tag" do
    assert :live_product_run in ExUnit.configuration()[:exclude]
    assert :provider_smoke in ExUnit.configuration()[:exclude]
  end

  test "the excluded-tag configuration does not depend on provider environment variables" do
    System.put_env("ANTHROPIC_API_KEY", "sk-task-008-should-not-matter")
    on_exit(fn -> System.delete_env("ANTHROPIC_API_KEY") end)

    assert :live_product_run in ExUnit.configuration()[:exclude]
    assert :provider_smoke in ExUnit.configuration()[:exclude]
  end
end
