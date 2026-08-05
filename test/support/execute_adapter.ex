defmodule Kapelle.Test.ExecuteAdapter do
  @moduledoc """
  `Kapelle.Executor.Adapter` test double matching the string-keyed payload a
  `Records.Run` row actually holds after an Ecto/jsonb round-trip — unlike
  `FakeAdapter`, which is only ever called with the in-memory, atom-keyed
  task map `Pipeline.run_sync/2` builds directly. Returns `{:error,
  :unexecutable}` for `%{"id" => "unexecutable"}` so execution-failure paths
  are reachable too.
  """

  @behaviour Kapelle.Executor.Adapter

  alias Kapelle.Executor.Result

  @impl true
  def execute(%{"id" => "unexecutable"}, _decision), do: {:error, :unexecutable}

  def execute(%{"id" => task_id}, _decision) do
    {:ok, Result.new!(%{task_id: task_id, status: :pass})}
  end
end
