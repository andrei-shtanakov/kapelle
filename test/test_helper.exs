ExUnit.start()
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
    "mismatched_judge" => Kapelle.Test.MismatchedJudge
  }
})
