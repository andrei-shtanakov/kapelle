defmodule Kapelle.Product.Oracle.Normalizer do
  @moduledoc """
  Deterministic reduction of the producer's raw trace events to domain
  observations (Task 8, oracle v0). The oracle is the golden set — a
  literal replay of the producer's own reference run — not this
  normalizer; the normalizer only strips technical noise (timestamps,
  paths, agent chatter, proposal-version counters) so the domain walk
  the trace records can be compared against `Kapelle.Product`'s own
  `View` + `NextStage` output.

  Only five raw event kinds carry a domain observation and are kept, in
  their original order; every other kind (`delta_applied`, `resumed`, ...)
  is technical and dropped whole:

    - `artifact_written` -> `iteration`/`stage` (from the idempotency key
      `"loop_id:iteration:role"`), `artifact_kind`/`artifact_ref` (the
      producer's own vocabulary: underscore kind, `kind://id` ref — see
      its `exchange-log` entries), `artifact_hash` (the output hash).
    - `transition` -> a single `proposal_transition` field, `"from->to"`.
    - `verdict` -> `iteration`, `verdict`, and `stop_reason_class` — the
      reason's leading clause up to the first `":"` (the whole reason
      when it has none), never the raw string with its issue counts.
    - `artifact_rejected` (v2) -> `iteration`/`stage` (from the key),
      `artifact_kind`, and a literal `rejected: true`. The producer's
      error-code list is dropped: its vocabulary is producer-specific and
      not comparable across languages; the domain fact is the rejection
      itself, at that stage, of that kind.
    - `stopped` (v2) -> the same shape as a `verdict` observation. The
      producer's fail-closed path records its terminal through `stopped`,
      not `verdict`, so before v2 a failed run normalized to almost
      nothing; happy/needs_human/resume traces carry no `stopped` events,
      so v2 leaves their normalized goldens byte-identical.

  A field that would be `nil` is dropped from its map rather than kept.
  """

  @spec version() :: String.t()
  def version, do: "v2"

  @spec normalize([map()]) :: [map()]
  def normalize(raw_trace_events) when is_list(raw_trace_events) do
    raw_trace_events
    |> Enum.map(&normalize_event/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_event(%{"event" => "artifact_written"} = event) do
    {iteration, stage} = split_key(event["key"])

    drop_nil(%{
      "iteration" => iteration,
      "stage" => stage,
      "artifact_kind" => underscore(event["kind"]),
      "artifact_ref" => "#{event["kind"]}://#{event["artifact"]}",
      "artifact_hash" => event["output_hash"]
    })
  end

  defp normalize_event(%{"event" => "transition"} = event) do
    drop_nil(%{"proposal_transition" => "#{event["from"]}->#{event["to"]}"})
  end

  defp normalize_event(%{"event" => "artifact_rejected"} = event) do
    {iteration, stage} = split_key(event["key"])

    drop_nil(%{
      "iteration" => iteration,
      "stage" => stage,
      "artifact_kind" => underscore(event["kind"]),
      "rejected" => true
    })
  end

  defp normalize_event(%{"event" => "stopped"} = event) do
    drop_nil(%{
      "iteration" => event["iteration"],
      "verdict" => event["verdict"],
      "stop_reason_class" => leading_clause(event["reason"])
    })
  end

  defp normalize_event(%{"event" => "verdict"} = event) do
    drop_nil(%{
      "iteration" => event["iteration"],
      "verdict" => event["verdict"],
      "stop_reason_class" => leading_clause(event["reason"])
    })
  end

  defp normalize_event(_technical_event), do: nil

  # The producer's idempotency key is "loop_id:iteration:role" (loop.py's
  # _Ctx.key/2); take the last two segments so a loop_id containing ":"
  # would not shift the parse.
  defp split_key(key) do
    [iteration, stage] = key |> String.split(":") |> Enum.take(-2)
    {String.to_integer(iteration), stage}
  end

  defp underscore(kind), do: String.replace(kind, "-", "_")

  defp leading_clause(reason), do: reason |> String.split(":", parts: 2) |> List.first()

  defp drop_nil(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)
end
