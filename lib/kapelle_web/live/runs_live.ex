defmodule KapelleWeb.RunsLive do
  @moduledoc """
  Read-only list of `Kapelle.Orchestrator.Records.Run`s (REQ-103): each
  row shows the run's `task_id` and current `status`. The first useful
  M3 page — cancel/retry are a separate slice.
  """

  use KapelleWeb, :live_view

  alias Kapelle.Orchestrator.Persistence

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, runs: Persistence.list_runs())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1 class="text-xl font-semibold">Runs</h1>

      <table class="table">
        <thead>
          <tr>
            <th>Task</th>
            <th>Status</th>
          </tr>
        </thead>
        <tbody id="runs">
          <tr :for={run <- @runs} id={"run-#{run.id}"}>
            <td>
              <.link navigate={~p"/runs/#{run.id}"}>{run.task_id}</.link>
            </td>
            <td>{run.status}</td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end
end
