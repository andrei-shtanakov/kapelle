defmodule Kapelle.Product.AgentCalls do
  @moduledoc """
  Durable usage carrier (design doc Q-03): append-only writes and
  read-only queries over `product_agent_calls`, one row per attempted
  live-agent call. `Kapelle.Product.Workers.StageShell` is the only
  writer — it records an attempt right after `produce/3` returns,
  *before* persisting the resulting document or routing any failure, so
  a call that was made but never reported usage (including one whose
  response was later rejected) still leaves a row. `nil` in any token
  column means the figure was not reported — never a silent zero.

  `Kapelle.Product.RunVerdict` is the only reader: it applies design doc
  Q-04's aggregation rule over the rows this module returns.
  """

  import Ecto.Query, only: [from: 2]

  alias Kapelle.Product.Records.AgentCallRow
  alias Kapelle.Repo

  @doc """
  Records one call attempt. `call_meta` is the third element a live
  `produce/3` may return (`Kapelle.Product.Agent.call_meta/0`), or `nil`
  when the call reported no metadata at all — a bare `{:ok, doc}`, or any
  `{:error, _}` — either way the row is written with every token column
  `nil`.
  """
  @spec record!(String.t(), non_neg_integer(), Kapelle.Product.Agent.role(), map() | nil) :: :ok
  def record!(loop_id, iteration, role, call_meta) do
    tokens = (call_meta && call_meta[:tokens]) || %{}

    %AgentCallRow{}
    |> AgentCallRow.changeset(%{
      loop_id: loop_id,
      iteration: iteration,
      role: to_string(role),
      model_id: call_meta && call_meta[:model_id],
      tokens_input: tokens[:input],
      tokens_output: tokens[:output],
      tokens_total: tokens[:total]
    })
    |> Repo.insert!()

    :ok
  end

  @doc "Every recorded attempt for `loop_id`, oldest first — read-only."
  @spec for_loop(String.t()) :: [AgentCallRow.t()]
  def for_loop(loop_id) when is_binary(loop_id) do
    Repo.all(from(c in AgentCallRow, where: c.loop_id == ^loop_id, order_by: [asc: c.id]))
  end
end
