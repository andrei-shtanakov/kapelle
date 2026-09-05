defmodule Mix.Tasks.Kapelle.Product.Report do
  @shortdoc "Prints one product loop's two-axis verdict, cost and interventions"

  @moduledoc """
  Makes a run's two-axis verdict visible per run (design doc §9.3), which
  is the half of that exit criterion a computed struct alone does not
  satisfy — someone has to be able to look.

      mix kapelle.product.report LOOP-001

  The output never rounds the two axes into one line and never prints a
  measured-looking zero for something that was not measured: an
  un-instrumented cost reads `not instrumented`, and counts that could not
  be established (damaged evidence) read `unknown`. See
  `Kapelle.Product.RunVerdict` for why that distinction is load-bearing.

  ## Looking at a loop must not run it

  `RunVerdict` promises to start no work — a promise a CLI wrapper can
  break without touching it. A plain `app.start` boots the whole
  supervision tree, Oban included, and outside `:test` the `product` queue
  is live (`config/config.exs`): the queue would pick up this very loop's
  available jobs, run stages, write artifacts — and then the Mix VM exits,
  cutting an in-flight job off mid-`perform/1` and leaving the row
  `executing` forever, which the next report would faithfully denounce as
  `:jobs_orphaned`. So this task configures Oban with no queues and no
  plugins *before* the app starts: the observation stays an observation.
  """

  use Mix.Task

  alias Kapelle.Product.RunVerdict

  # No `@requirements`: the app has to be started by hand here, after Oban
  # has been muted — see the moduledoc.
  @impl Mix.Task
  def run([loop_id]) do
    start_without_executors!()

    case RunVerdict.for_loop(loop_id) do
      {:ok, verdict} -> Mix.shell().info(format(verdict))
      {:error, :not_found} -> Mix.raise("unknown loop_id: #{loop_id}")
    end
  end

  def run(_argv), do: Mix.raise("usage: mix kapelle.product.report <loop_id>")

  defp start_without_executors! do
    Mix.Task.run("app.config")

    :kapelle
    |> Application.fetch_env!(Oban)
    |> read_only_oban()
    |> then(&Application.put_env(:kapelle, Oban, &1))

    Mix.Task.run("app.start")
  end

  @doc """
  Strips execution out of an Oban configuration: no queues to pick work up,
  no plugins to move it. Public so the read-only guarantee can be tested
  without booting an application.
  """
  @spec read_only_oban(keyword()) :: keyword()
  def read_only_oban(oban_config) do
    Keyword.merge(oban_config, queues: false, plugins: false)
  end

  @doc """
  Renders a verdict as the block the task prints. Public so the rendering
  can be tested without a Mix invocation.
  """
  @spec format(RunVerdict.t()) :: String.t()
  def format(%RunVerdict{} = verdict) do
    Enum.join(
      [
        "loop:    #{verdict.loop_id}",
        "product: #{verdict.product} — #{verdict.product_reason}",
        "harness: #{verdict.harness}#{findings(verdict.harness_findings)}",
        "",
        "cost:",
        cost_lines(verdict.cost),
        "",
        "interventions:",
        intervention_lines(verdict.interventions)
      ],
      "\n"
    )
  end

  defp findings([]), do: ""

  defp findings(findings) do
    "\n" <>
      Enum.map_join(findings, "\n", fn finding ->
        "  - #{finding.class} (#{finding.severity}): #{inspect(finding.detail)}"
      end)
  end

  defp cost_lines(cost) do
    Enum.map_join(
      [
        {"iterations", "#{value(cost.iterations_used)} / #{value(cost.max_iterations)}"},
        {"stage jobs", value(cost.stage_jobs)},
        {"attempts", value(cost.attempts)},
        {"retries", value(cost.retries)},
        {"discarded", value(cost.discarded_jobs)},
        {"cancelled", value(cost.cancelled_jobs)},
        {"executing", value(cost.executing_jobs)},
        {"orphaned", value(cost.orphaned_jobs)},
        {"artifact revisions", value(cost.artifact_revisions)},
        {"wall ms", value(cost.wall_ms)},
        {"tokens", tokens(cost)}
      ],
      "\n",
      fn {label, value} -> "  #{String.pad_trailing(label <> ":", 20)}#{value}" end
    )
  end

  defp tokens(%{tokens: nil, tokens_unavailable: :not_instrumented}), do: "not instrumented"
  defp tokens(%{tokens: nil, tokens_unavailable: reason}), do: "unknown (#{reason})"
  defp tokens(%{tokens: tokens}), do: to_string(tokens)

  defp intervention_lines(interventions) do
    Enum.map_join(
      [
        {"holds", value(interventions.holds)},
        {"resumes", refs(interventions.resumes, interventions.resume_refs)},
        {"waivers", refs(interventions.waivers, interventions.waiver_refs)}
      ],
      "\n",
      fn {label, value} -> "  #{String.pad_trailing(label <> ":", 20)}#{value}" end
    )
  end

  defp refs(nil, _refs), do: "unknown"
  defp refs(count, []), do: to_string(count)
  defp refs(count, refs), do: "#{count} (#{Enum.join(refs, ", ")})"

  # An unestablished number is "unknown", never 0 — the same rule the
  # verdict itself follows.
  defp value(nil), do: "unknown"
  defp value(value), do: to_string(value)
end
