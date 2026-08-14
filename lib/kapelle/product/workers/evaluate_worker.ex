defmodule Kapelle.Product.Workers.EvaluateWorker do
  @moduledoc """
  The apply stage over `Kapelle.Product.Workers.StageShell` (design doc
  §5, Task 7): no agent call. Records the loop's own iteration as
  applied onto the proposal — the audit trail `NextStage` itself never
  reads back to make its ready/continue/needs_human decision (that
  decision comes only from the research pack's/concept draft's own
  open items), but that the vendored schemas and the golden oracle both
  require to exist.

  Two persists when this is the very first apply of the whole loop
  (`status == "draft"`, mirroring the producer's own `_set_status` at
  loop start): a status-flip snapshot (`draft -> in_iteration`, its own
  version bump) followed by the delta-apply snapshot proper. Every later
  round only does the delta-apply snapshot. Derived against the golden
  proposal/exchange-log fixtures (controller's STOP posture, plan Task
  7): the delta-log entry is `%{"iteration", "concept_draft", "delta"}`
  — the concept draft's own `id` and `proposal_delta` field, *not* the
  `{iteration, rp, cd}` shape the plan text guessed — and each apply
  appends its own exchange-log entry (`actor: "orchestration"`,
  `artifact_kind: "product_proposal_patch"`) in addition to research's
  and creator's, three entries per round total.

  A final "ready" verdict gets one more proposal snapshot bumping
  `status` to `"ready_for_business"` (nothing else changes) — computed
  here, after the delta-apply, against a fresh view; the ordinary
  `needs_human`/`continue` outcomes are left entirely to
  `StageShell.run/2`'s generic next-stage step, since the proposal
  itself is untouched in both those cases (producer semantics).
  """

  use Oban.Worker, queue: :product

  alias Kapelle.Product.{NextStage, View}
  alias Kapelle.Product.Workers.StageShell

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}), do: StageShell.run(args, stage_impl())

  defp stage_impl do
    %{
      stage: :apply,
      output_exists?: &output_exists?/2,
      execute: &execute/3
    }
  end

  defp output_exists?(view, iteration), do: NextStage.delta_applied?(view.proposal, iteration)

  defp execute(view, iteration, loop) do
    rp = view.research_packs[iteration]
    cd = view.concept_drafts[iteration]
    now = StageShell.now_iso()

    with {:ok, base} <- maybe_flip_to_in_iteration(view.proposal, loop, now),
         {:ok, applied} <- apply_delta(base, rp, cd, iteration, loop, now),
         :ok <-
           StageShell.append_exchange_entry(loop, view, %{
             "iteration" => iteration,
             "actor" => "orchestration",
             "artifact_kind" => "product_proposal_patch",
             "artifact_ref" => "proposal://" <> loop.proposal_id,
             "at" => now
           }) do
      maybe_finalize_ready(applied, loop, now)
    end
  end

  defp maybe_flip_to_in_iteration(%{"status" => "draft"} = proposal, loop, now) do
    flipped = %{
      proposal
      | "status" => "in_iteration",
        "version" => proposal["version"] + 1,
        "updated_at" => now
    }

    with :ok <- StageShell.persist_document(:product_proposal, flipped, loop.loop_id) do
      {:ok, flipped}
    end
  end

  defp maybe_flip_to_in_iteration(proposal, _loop, _now), do: {:ok, proposal}

  defp apply_delta(base, rp, cd, iteration, loop, now) do
    delta_log = get_in(base, ["content", "delta_log"]) || []

    entry = %{
      "iteration" => iteration,
      "concept_draft" => cd["id"],
      "delta" => cd["proposal_delta"]
    }

    applied = %{
      base
      | "version" => base["version"] + 1,
        "iteration" => iteration,
        "content" => Map.put(base["content"] || %{}, "delta_log", delta_log ++ [entry]),
        "refs" =>
          Map.merge(base["refs"], %{
            "latest_research_pack" => "research-pack://" <> rp["id"],
            "latest_concept_draft" => "concept-draft://" <> cd["id"]
          }),
        "updated_at" => now
    }

    with :ok <- StageShell.persist_document(:product_proposal, applied, loop.loop_id) do
      {:ok, applied}
    end
  end

  # Whether this round's apply reached the loop's terminal "ready"
  # verdict is decided the same way the rest of the system decides it:
  # a fresh `View.build/1` + `NextStage.compute/2` over what was just
  # persisted. `needs_human` and "keep going" both leave the proposal
  # untouched here — `StageShell.run/2`'s generic advance step derives
  # the same verdict again right after this returns and handles the
  # loop's status/projection either way.
  defp maybe_finalize_ready(proposal, loop, now) do
    with {:ok, fresh_view} <- View.build(loop.loop_id) do
      case NextStage.compute(fresh_view, loop.max_iterations) do
        {:terminal, :ready, _reason} ->
          ready = %{
            proposal
            | "status" => "ready_for_business",
              "version" => proposal["version"] + 1,
              "updated_at" => now
          }

          StageShell.persist_document(:product_proposal, ready, loop.loop_id)

        _not_ready_yet ->
          :ok
      end
    end
  end
end
