defmodule Kapelle.Executor.FakeAdapter do
  @moduledoc """
  `Kapelle.Executor.Adapter` test double returning a canned `Result` — makes
  no network calls. Used to prove the M1 pipeline and by dev seeds.

  The outcome defaults to `:pass` and can be overridden per task via
  `task[:fake_result]`, either a map of `Result.new!/1` attrs merged over the
  default, or an `{:error, reason}` tuple returned as-is to simulate an
  execution failure. An explicit `nil` means "no overrides"; any other value
  yields `{:error, {:invalid_fake_result, value}}`.
  """

  @behaviour Kapelle.Executor.Adapter

  alias Kapelle.Executor.Result

  @impl true
  def execute(%{id: task_id} = task, _decision) do
    case Map.get(task, :fake_result) do
      nil ->
        canned(task_id, %{})

      {:error, _reason} = error ->
        error

      %{} = overrides ->
        canned(task_id, overrides)

      other ->
        {:error, {:invalid_fake_result, other}}
    end
  end

  defp canned(task_id, overrides) do
    attrs = Map.merge(%{task_id: task_id, status: :pass}, overrides)
    {:ok, Result.new!(attrs)}
  end
end
