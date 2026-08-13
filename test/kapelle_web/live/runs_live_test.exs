defmodule KapelleWeb.RunsLiveTest do
  use KapelleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Kapelle.Orchestrator.Persistence

  test "lists runs with their task id and status", %{conn: conn} do
    {:ok, run} = Persistence.create_run(%{id: "task-abc-123"})

    {:ok, _live, html} = live(conn, ~p"/runs")

    assert html =~ run.task_id
    assert html =~ run.status
  end
end
