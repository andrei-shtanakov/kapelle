defmodule Kapelle.Product.Events do
  @moduledoc """
  PubSub topic naming and subscribe/broadcast helpers for a loop's product
  artifacts (design doc §5). `Kapelle.Product.Store.put/2` broadcasts an
  `Event` only after it has committed a successful insert — never on
  `:noop`, never on a conflict — so a subscriber never sees an event for
  bytes that aren't actually in the store.
  """

  alias Kapelle.Product.Event
  alias Phoenix.PubSub

  @pubsub Kapelle.PubSub

  @doc """
  Builds the PubSub topic name for `loop_id`.
  """
  @spec topic(String.t()) :: String.t()
  def topic(loop_id), do: "product:loop:#{loop_id}"

  @doc """
  Subscribes the calling process to `loop_id`'s topic.
  """
  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(loop_id) do
    PubSub.subscribe(@pubsub, topic(loop_id))
  end

  @doc """
  Broadcasts `event` to its `loop_id`'s subscribers.
  """
  @spec broadcast(Event.t()) :: :ok
  def broadcast(%Event{loop_id: loop_id} = event) do
    PubSub.broadcast(@pubsub, topic(loop_id), event)
  end
end
