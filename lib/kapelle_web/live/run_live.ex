defmodule KapelleWeb.RunLive do
  @moduledoc """
  Read-only detail view for a single `Kapelle.Orchestrator.Records.Run`
  (REQ-103): the task, the routing decision, the execution result, the
  verdict, and the current status. Subscribes to `RunEvents` so the page
  reflects the pipeline's progress as it happens, without the client
  reloading. Cancel/retry are a separate slice — this view only ever
  reads.
  """

  use KapelleWeb, :live_view

  alias Kapelle.Orchestrator.Persistence
  alias Kapelle.Orchestrator.RunEvents

  @impl true
  def mount(%{"id" => raw_id}, _session, socket) do
    run_id = cast_run_id!(raw_id)
    if connected?(socket), do: RunEvents.subscribe(run_id)

    {:ok, assign(socket, run: Persistence.get_run_with_details!(run_id))}
  end

  @impl true
  def handle_info({:run_updated, run_id}, socket) do
    {:noreply, assign(socket, run: Persistence.get_run_with_details!(run_id))}
  end

  # A non-UUID `:id` must be a 404, not an `Ecto.Query.CastError` 500:
  # raising `Ecto.NoResultsError` lets Phoenix render not-found, same as
  # an unknown-but-valid UUID.
  defp cast_run_id!(raw_id) do
    case Ecto.UUID.cast(raw_id) do
      {:ok, run_id} -> run_id
      :error -> raise Ecto.NoResultsError, queryable: Kapelle.Orchestrator.Records.Run
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1 class="text-xl font-semibold">Run {@run.task_id}</h1>

      <div id="run-status">
        <strong>Status:</strong> {@run.status}
      </div>

      <div id="run-task">
        <strong>Task ID:</strong> {@run.task_id}
      </div>

      <div :if={@run.decision} id="run-decision">
        <h2 class="font-semibold">Decision</h2>
        <p>Provider: {@run.decision.target["provider"]}</p>
        <p>Model: {@run.decision.target["model"]}</p>
        <p>Decided at: {@run.decision.decided_at}</p>

        <div :if={@run.decision.run_task} id="run-result">
          <h2 class="font-semibold">Result</h2>
          <p>Status: {@run.decision.run_task.status}</p>
          <p :if={@run.decision.run_task.duration_ms}>
            Duration: {@run.decision.run_task.duration_ms}ms
          </p>
        </div>

        <div :if={@run.decision.verdict} id="run-verdict">
          <h2 class="font-semibold">Verdict</h2>
          <p>Score: {@run.decision.verdict.total_score}</p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
