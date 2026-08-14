defmodule Kapelle.Product.Loop do
  @moduledoc """
  Port of the producer's `init_loop` (design doc §5): idea document ->
  running loop. Persists the idea, the initial proposal snapshot
  (version 1) and the loop's config + state projection, then enqueues
  the first stage job — durable boundary order throughout (owner's
  decision, 2026-08-14): nothing observable before the artifact that
  justifies it.

  No exchange-log snapshot is persisted here (controller's ruling,
  2026-08-14, resolving the STOP this task hit): the pinned producer's
  own `init_loop` (loop.py:115-167) writes only idea + proposal +
  loop-state at init — no exchange-log file exists yet. The log is born
  at the first `_append_exchange` call already carrying one entry; the
  vendored schema's `entries` `minItems: 1` encodes exactly that, and
  correctly rejected this task's first draft (which invented an
  `"entries" => []` revision-0 snapshot the producer never writes).
  `revision_of(:exchange_log, doc) = length(entries)`, so the first
  snapshot Task 7's research-stage worker stores is already revision 1.

  The initial proposal shape is the producer's, byte-faithful in intent
  (verified against the pin): built here exactly as specified and then
  validated through `Kapelle.Product.Validator` before
  `Kapelle.Product.Store.put/2` — if the vendored schema ever rejects
  it, `start/2` returns the typed `{:invalid_artifact, ...}` error
  verbatim rather than silently reshaping the port's output.
  """

  alias Kapelle.Product.{CanonicalHash, Identity, Loader, Loops, Record, Store, Validator}
  alias Kapelle.Product.Workers.{ResearchWorker, StageShell}

  @type opts :: [
          loop_id: String.t(),
          proposal_id: String.t(),
          exchange_log_id: String.t(),
          max_iterations: pos_integer(),
          agent: String.t(),
          now_iso: String.t(),
          research_worker: module()
        ]

  @doc """
  Starts a loop from a raw idea YAML/JSON document and the given `opts`.
  An invalid idea returns its typed loader error with nothing persisted;
  a `loop_id` that already has a config row returns
  `{:error, :already_initialized}`, also with nothing further persisted.
  """
  @spec start(binary(), opts()) ::
          {:ok, Kapelle.Product.Records.LoopRow.t()} | {:error, term()}
  def start(idea_yaml, opts) when is_binary(idea_yaml) do
    loop_id = Keyword.fetch!(opts, :loop_id)

    with {:ok, idea} <- Loader.load(:idea, idea_yaml),
         {:ok, loop_row} <- Loops.create(loop_config(loop_id, idea, opts)),
         {:ok, _} <- Store.put(idea, loop_id),
         {:ok, _proposal_doc} <- store_proposal(idea, loop_id, opts),
         {:ok, _row} <- Loops.put_state_projection(loop_id, state_projection(idea, opts)),
         {:ok, _job} <- enqueue_first_stage(idea, loop_id, opts) do
      {:ok, loop_row}
    end
  end

  defp loop_config(loop_id, idea, opts) do
    %{
      loop_id: loop_id,
      idea_identity: idea.id,
      proposal_id: Keyword.fetch!(opts, :proposal_id),
      exchange_log_id: Keyword.fetch!(opts, :exchange_log_id),
      max_iterations: Keyword.fetch!(opts, :max_iterations),
      agent: Keyword.fetch!(opts, :agent)
    }
  end

  # Producer-verbatim initial proposal shape (version 1, status "draft") —
  # see moduledoc for the STOP posture if the vendored schema rejects it.
  defp store_proposal(idea, loop_id, opts) do
    now = now_iso(opts)

    doc = %{
      "proposal_id" => Keyword.fetch!(opts, :proposal_id),
      "idea_ref" => "idea://" <> idea.id,
      "version" => 1,
      "status" => "draft",
      "iteration" => 0,
      "refs" => %{
        "exchange_log" => "exchange-log://" <> Keyword.fetch!(opts, :exchange_log_id)
      },
      "content" => %{"delta_log" => []},
      "created_at" => now,
      "updated_at" => now
    }

    with {:ok, _} <- store_document(:product_proposal, doc, loop_id) do
      {:ok, doc}
    end
  end

  defp store_document(kind, doc, loop_id) do
    with :ok <- Validator.validate(kind, doc),
         {:ok, id} <- Identity.of(kind, doc) do
      Store.put(%Record{kind: kind, id: id, doc: doc}, loop_id)
    end
  end

  # Producer-format loop-state document, projected via
  # `Kapelle.Product.Loops.put_state_projection/2` — not the authoritative
  # store (owner's loop-state-leaves-the-store decision, 2026-08-14).
  defp state_projection(idea, opts) do
    %{
      "loop_id" => Keyword.fetch!(opts, :loop_id),
      "idea_ref" => "idea://" <> idea.id,
      "idea_input_hash" => CanonicalHash.hash(idea.doc),
      "proposal_id" => Keyword.fetch!(opts, :proposal_id),
      "exchange_log_id" => Keyword.fetch!(opts, :exchange_log_id),
      "max_iterations" => Keyword.fetch!(opts, :max_iterations),
      "stop" => nil
    }
  end

  defp enqueue_first_stage(idea, loop_id, opts) do
    worker_module = Keyword.get(opts, :research_worker, ResearchWorker)
    input_hash = CanonicalHash.hash(idea.doc)

    StageShell.enqueue_stage(worker_module, loop_id, {:research, 0}, input_hash)
  end

  # `now_iso` is threaded through `opts` for determinism; when the caller
  # omits it, the default is resolved here at call time (owner's
  # decision, 2026-08-14), never baked in as a fixed constant.
  defp now_iso(opts) do
    Keyword.get_lazy(opts, :now_iso, fn -> DateTime.utc_now() |> DateTime.to_iso8601() end)
  end
end
