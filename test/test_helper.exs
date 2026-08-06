# `:provider_smoke` hits a real provider API (see
# Kapelle.Executor.ChainAdapterSmokeTest) — excluded by default so `mix
# test` stays network-free (NFR-002). Opt in with
# `mix test --include provider_smoke` and ANTHROPIC_API_KEY set.
ExUnit.start(exclude: [:provider_smoke])
Ecto.Adapters.SQL.Sandbox.mode(Kapelle.Repo, :manual)

# Test-only Policy/Adapter/Judge doubles, resolved via
# Kapelle.Orchestrator.Workers.OverrideRegistry. Kept out of lib/ so
# production code has no test/support dependency (see DESIGN-004).
Application.put_env(:kapelle, :orchestrator_overrides, %{
  policy: %{
    "stub_policy" => Kapelle.Test.StubPolicy,
    "route_policy" => Kapelle.Test.RoutePolicy
  },
  adapter: %{
    "execute_adapter" => Kapelle.Test.ExecuteAdapter
  },
  judge: %{
    "failing_judge" => Kapelle.Test.FailingJudge,
    "exploding_judge" => Kapelle.Test.ExplodingJudge,
    "mismatched_judge" => Kapelle.Test.MismatchedJudge,
    "echoing_judge" => Kapelle.Test.EchoingJudge
  }
})
