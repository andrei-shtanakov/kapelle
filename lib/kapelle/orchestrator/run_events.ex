defmodule Kapelle.Orchestrator.RunEvents do
  @moduledoc """
  PubSub topic naming and subscribe/broadcast helpers for a `Run`'s state
  changes (REQ-103). `RunLive` subscribes per run id to update its detail
  view without a reload; the orchestrator workers broadcast whenever they
  persist a stage that changes what that view shows.

  The broadcast payload carries no state of its own — just `run_id` — so
  a subscriber always re-reads current state from `Persistence` rather
  than trusting a payload that could race a concurrent write.
  """

  alias Phoenix.PubSub

  @pubsub Kapelle.PubSub

  @doc """
  Builds the PubSub topic name for `run_id`.
  """
  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(run_id), do: "run:#{run_id}"

  @doc """
  Subscribes the calling process to `run_id`'s topic.
  """
  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(run_id) do
    PubSub.subscribe(@pubsub, topic(run_id))
  end

  @doc """
  Broadcasts a `{:run_updated, run_id}` message to `run_id`'s subscribers.
  """
  @spec broadcast(Ecto.UUID.t()) :: :ok
  def broadcast(run_id) do
    PubSub.broadcast(@pubsub, topic(run_id), {:run_updated, run_id})
  end
end
