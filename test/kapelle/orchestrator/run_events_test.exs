defmodule Kapelle.Orchestrator.RunEventsTest do
  use ExUnit.Case, async: true

  alias Kapelle.Orchestrator.RunEvents

  test "subscribe/1 then broadcast/1 delivers a :run_updated message tagged with the run id" do
    run_id = Ecto.UUID.generate()
    :ok = RunEvents.subscribe(run_id)

    :ok = RunEvents.broadcast(run_id)

    assert_receive {:run_updated, ^run_id}
  end

  test "broadcast/1 is scoped to run_id: a subscriber to a different run receives nothing" do
    run_id = Ecto.UUID.generate()
    other_run_id = Ecto.UUID.generate()
    :ok = RunEvents.subscribe(run_id)

    :ok = RunEvents.broadcast(other_run_id)

    refute_receive {:run_updated, _}, 50
  end
end
