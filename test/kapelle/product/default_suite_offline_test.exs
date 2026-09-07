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

    # The invariant (BEH-25) is about the *default* run only. The
    # `:provider_smoke` and `:live_product_run` tags are the documented
    # opt-in (`mix test --include provider_smoke`, see test_helper.exs)
    # for tests that legitimately make a real outgoing provider call —
    # counting those as a violation would make the documented opt-in
    # path permanently red for doing exactly what it says on the label.
    # Gate on `ExUnit.configuration()[:include]` rather than skipping
    # attach/registration above: the handler counting is harmless by
    # itself, only the halt-on-violation decision needs to know which
    # run this is.
    network_tags_included? =
      Enum.any?(
        [:provider_smoke, :live_product_run],
        &(&1 in ExUnit.configuration()[:include])
      )

    if attempts > 0 and not network_tags_included? do
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

  test "provider model resolution (AC-16) does not depend on provider environment variables" do
    # `ExUnit.configuration()[:exclude]` is fixed once at `ExUnit.start/1`
    # (test_helper.exs), before any test body runs — setting an env var
    # from inside a test can never change it, so asserting against it
    # here would be green by construction. Instead this exercises the
    # actual path AC-16 is about: resolving a catalog id to the langchain
    # model struct that would be used for a real call
    # (`Kapelle.Providers.ModelFactory.build/1`, reached via
    # `Kapelle.Product.Agent.resolve/1`'s `model:` scheme). Neither reads
    # `ANTHROPIC_API_KEY` (or any provider env var) — the api key is only
    # resolved lazily, at actual request time, deep in langchain's HTTP
    # path — so the built struct is asserted identical with and without
    # the variable set.
    System.delete_env("ANTHROPIC_API_KEY")
    on_exit(fn -> System.delete_env("ANTHROPIC_API_KEY") end)

    catalog_id = "anthropic@claude-sonnet-5"

    assert {:ok, {Kapelle.Product.LiveAgent, ^catalog_id}} =
             Kapelle.Product.Agent.resolve("model:" <> catalog_id)

    {:ok, without_env_var} = Kapelle.Providers.ModelFactory.build(catalog_id)

    System.put_env("ANTHROPIC_API_KEY", "sk-task-008-should-not-matter")
    {:ok, with_env_var} = Kapelle.Providers.ModelFactory.build(catalog_id)

    assert without_env_var == with_env_var
  end
end
