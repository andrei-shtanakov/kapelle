defmodule Kapelle.Router.RulesPolicyTest do
  use ExUnit.Case, async: true

  alias Kapelle.Providers.Catalog
  alias Kapelle.Router.Decision
  alias Kapelle.Router.RulesPolicy

  @table [
    {%{id: "task-1", type: :code_gen}, %{provider: "anthropic", model: "claude-sonnet-5"}},
    {%{id: "task-2", type: :summarize}, %{provider: "anthropic", model: "claude-haiku-4-5"}},
    {%{id: "task-3", type: :general}, %{provider: "anthropic", model: "claude-sonnet-5"}}
  ]

  test "route/2 returns a Decision with the expected target for each known task shape" do
    for {task, expected_target} <- @table do
      assert {:ok, %Decision{} = decision} = RulesPolicy.route(task, [])
      assert decision.target == expected_target
      assert decision.task_id == task.id
    end
  end

  test "route/2 is deterministic: same task always yields the same target" do
    for {task, _expected_target} <- @table do
      {:ok, first} = RulesPolicy.route(task, [])
      {:ok, second} = RulesPolicy.route(task, [])

      assert first.target == second.target
      assert first.task_id == second.task_id
    end
  end

  test "route/2 returns a unique decision_id on every call" do
    task = %{id: "task-1", type: :code_gen}

    {:ok, first} = RulesPolicy.route(task, [])
    {:ok, second} = RulesPolicy.route(task, [])

    assert first.decision_id != second.decision_id
    assert {:ok, _} = Ecto.UUID.cast(first.decision_id)
    assert {:ok, _} = Ecto.UUID.cast(second.decision_id)
  end

  # The catalog is the SSOT for provider addresses, and routing does not
  # consult it: a target absent from `priv/catalog/models.toml` still yields
  # a valid `Decision` and persists it. Execution fails later, in
  # `Execution.run/3`'s own catalog lookup — which happens before the
  # adapter is ever called, so an override adapter does not step around it
  # and `Pipeline.run_sync/2` fails exactly as `ExecuteWorker` does. On the
  # async path the job then retries to `max_attempts` before
  # `Terminal.fail/3` lands the run in `"failed"`: a slow terminal failure,
  # not a permanently pending one.
  #
  # Nothing else in the suite crosses that seam, and not for the reason one
  # might assume: both `:summarize` pipeline tests pass `policy: StubPolicy`,
  # which routes every task to `anthropic@claude-sonnet-5` regardless of
  # type, so `RulesPolicy`'s own haiku target is executed nowhere in the
  # suite.
  #
  # The guarantee is bounded by `@table`. The first test in this file checks
  # that every row matches what the policy returns; nothing checks the
  # converse, so a new `route/2` clause added without a matching row slips
  # past this guard. Add the row when you add the clause.
  test "every routed target exists in the provider catalog" do
    for {_task, %{provider: provider, model: model}} <- @table do
      id = "#{provider}@#{model}"

      # `assert {:ok, _} = ...` would report this as a bare MatchError and
      # bury the one fact the reader needs — which id is missing.
      assert match?({:ok, _entry}, Catalog.get(id)),
             "RulesPolicy routes to #{id}, which priv/catalog/models.toml does not declare"
    end
  end

  test "route/2 returns {:error, _} for an unknown task shape" do
    assert {:error, _reason} = RulesPolicy.route(%{id: "task-1", type: :unsupported}, [])
    assert {:error, _reason} = RulesPolicy.route(%{id: "task-1"}, [])
    assert {:error, _reason} = RulesPolicy.route(%{type: :code_gen}, [])
    assert {:error, _reason} = RulesPolicy.route(%{}, [])
  end

  test "RulesPolicy implements the Kapelle.Router.Policy behaviour" do
    assert Kapelle.Router.Policy in (RulesPolicy.module_info(:attributes)
                                     |> Keyword.get_values(:behaviour)
                                     |> List.flatten())
  end
end
