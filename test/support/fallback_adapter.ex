defmodule Kapelle.Test.FallbackAdapter do
  @moduledoc """
  `Kapelle.Executor.Adapter` test double that reports a provider `:error`
  for the primary `anthropic@claude-sonnet-5` target and a `:pass` for its
  declared fallback `anthropic@claude-opus-5` — makes no network calls.

  Used to prove that routed execution (`Pipeline.run_sync/2`,
  `ExecuteWorker`) actually walks a catalog entry's `fallback` chain
  instead of calling the adapter once against the routed target only.
  """

  @behaviour Kapelle.Executor.Adapter

  alias Kapelle.Executor.Result

  @impl true
  def execute(%{id: _task_id}, %{target: %{provider: "anthropic", model: "claude-sonnet-5"}}) do
    {:error, :provider_down}
  end

  def execute(%{id: task_id}, %{target: %{provider: "anthropic", model: "claude-opus-5"}}) do
    {:ok, Result.new!(%{task_id: task_id, status: :pass})}
  end

  def execute(_task, decision), do: {:error, {:unexpected_target, decision.target}}
end
