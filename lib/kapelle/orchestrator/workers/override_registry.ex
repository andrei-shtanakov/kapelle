defmodule Kapelle.Orchestrator.Workers.OverrideRegistry do
  @moduledoc """
  Maps short, JSON-serializable string keys to the `:policy`/`:adapter`/
  `:judge` modules `Pipeline.submit/2` and its workers pass through Oban job
  args, which must be plain JSON and can't carry module atoms directly.

  Test-only doubles are added without touching `lib/` by setting
  `Application.put_env(:kapelle, :orchestrator_overrides, %{kind => %{key =>
  module}})` (typically from `test/test_helper.exs`, or per-test `setup` for
  a double that's only valid in one test).
  """

  alias Kapelle.Evaluator.FakeJudge
  alias Kapelle.Executor.FakeAdapter
  alias Kapelle.Router.RulesPolicy

  @type kind :: :policy | :adapter | :judge

  @base %{
    policy: %{"rules_policy" => RulesPolicy},
    adapter: %{"fake_adapter" => FakeAdapter},
    judge: %{"fake_judge" => FakeJudge}
  }

  @doc """
  Returns the registered string key for `module` under `kind`.

  Raises `ArgumentError` if `module` isn't registered under `kind`.
  """
  @spec key_for(kind(), module()) :: String.t()
  def key_for(kind, module) do
    known = registry(kind)

    known
    |> Enum.find(fn {_key, registered_module} -> registered_module == module end)
    |> case do
      {key, _module} ->
        key

      nil ->
        raise ArgumentError,
              "no #{inspect(kind)} key registered for #{inspect(module)} " <>
                "(known modules: #{inspect(Map.values(known))})"
    end
  end

  @doc """
  Resolves `key` to its module under `kind`.

  Raises `ArgumentError` with the unknown key and the known keys for `kind`
  if `key` isn't registered.
  """
  @spec resolve!(kind(), String.t()) :: module()
  def resolve!(kind, key) do
    known = registry(kind)

    case Map.fetch(known, key) do
      {:ok, module} ->
        module

      :error ->
        raise ArgumentError,
              "unknown #{inspect(kind)} override #{inspect(key)} " <>
                "(known keys: #{inspect(Map.keys(known))})"
    end
  end

  defp registry(kind) do
    case Map.fetch(@base, kind) do
      {:ok, base} ->
        overrides = Application.get_env(:kapelle, :orchestrator_overrides, %{})
        Map.merge(base, Map.get(overrides, kind, %{}))

      :error ->
        raise ArgumentError,
              "unknown override kind #{inspect(kind)} (known kinds: #{inspect(Map.keys(@base))})"
    end
  end
end
