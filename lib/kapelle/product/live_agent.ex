defmodule Kapelle.Product.LiveAgent do
  @moduledoc """
  `Kapelle.Product.Agent` implementation for the `model:` scheme (design
  doc §"Механика"): offline preflight of the catalog id, a real
  langchain-backed call, failure-table classification, response
  validation, and provenance stamping.

  `resolve/1` never reaches this module for a malformed address — that
  shape check lives entirely in `Kapelle.Product.Agent`. What lands here
  is a syntactically valid `<provider>@<model>` catalog id
  (`context.key`), and everything this module does with it up to the
  actual provider call is offline: `preflight/1` loads the catalog from
  the **configured** path (`:product_catalog_path`, default the same
  `priv/catalog/models.toml` `Kapelle.Providers.Catalog` itself defaults
  to — a test can point this at a `tmp_dir` file to prove
  `catalog_unreadable`/`catalog_invalid` without touching the shared
  catalog file other suites read), finds the entry itself (mirroring
  what `Catalog.get/1` does internally, so `Catalog` itself needs no
  change), and builds the langchain model via `ModelFactory.build/1` —
  now overloaded to accept an already-resolved
  `Kapelle.Providers.Catalog.Entry` directly, so the entry `preflight/1`
  found from the *configured* path is exactly the one the model is built
  from, not a second lookup against `Catalog`'s own default path.

  Failure classification (design doc Q-05) reads `LangChainError.original`
  for a transport error or a recoverable HTTP status — both closer to the
  truth than the SDK's own `type`, which collapses distinct failures
  (an unreachable host and a revoked key both surface as
  `"unhandled_error"`/`"unexpected_response"`) — and falls back to `type`
  only once neither is recoverable. `original` is read, never re-exposed:
  callers only ever see `{:provider_error, type, message}`, so neither the
  `ChatAnthropic` struct (which carries `api_key`) nor an `Ecto.Changeset`
  (whose `data` carries that same struct) ever reaches a `stop_reason`,
  a persisted document, or this module's own return value (BEH-29).

  Two failure shapes are deliberately not members of
  `Kapelle.Product.Agent.failure()` (design doc Q-02): `provider_auth_failed`
  (a configuration-of-the-run failure — missing/invalid/revoked key) and
  `unclassified_provider_failure` (an unrecognized failure, classified
  fail-closed rather than guessed at). Both route through
  `Kapelle.Product.Workers.StageShell`'s existing catch-all
  `{:error, reason}` branch — terminal, not retried, product axis stays
  `:unknown` — exactly like an unresolvable address.

  No fallback chain (design doc Q-06): a catalog entry names exactly one
  model, and a failed call stays a failed call. Attribution
  (`call_meta.model_id` / the stamped `produced_by.model`) is always the
  entry actually invoked, which is Q-06's other half — cost is
  observable even on the day a fallback chain is added.
  """

  @behaviour Kapelle.Product.Agent

  alias Kapelle.Product.{Contracts, StrictParse, Validator}
  alias Kapelle.Product.Workers.StageShell
  alias Kapelle.Providers.{Catalog, ModelFactory}
  alias LangChain.Chains.LLMChain
  alias LangChain.LangChainError
  alias LangChain.Message
  alias LangChain.TokenUsage
  alias LangChain.Utils.ChainResult

  @impl Kapelle.Product.Agent
  def produce(role, iteration, %{key: catalog_id} = context) do
    with {:ok, {entry, model}} <- preflight(catalog_id) do
      call_model(role, iteration, context, entry, model)
    end
  end

  # --- offline preflight (design doc BEH-05): no branch below ever makes
  # a network call. ---

  defp preflight(catalog_id) do
    with {:ok, entries} <- load_catalog(),
         {:ok, entry} <- find_entry(entries, catalog_id) do
      build_model(entry)
    end
  end

  defp load_catalog do
    case Catalog.load(catalog_path()) do
      {:ok, entries} ->
        {:ok, entries}

      {:error, {:catalog_file_not_found, _} = reason} ->
        {:error, {:catalog_unreadable, reason}}

      {:error, {:invalid_toml, _} = reason} ->
        {:error, {:catalog_unreadable, reason}}

      {:error, reason} ->
        {:error, {:catalog_invalid, reason}}
    end
  end

  defp catalog_path do
    Application.get_env(
      :kapelle,
      :product_catalog_path,
      Application.app_dir(:kapelle, "priv/catalog/models.toml")
    )
  end

  defp find_entry(entries, catalog_id) do
    case Enum.find(entries, &(&1.id == catalog_id)) do
      nil -> {:error, {:model_not_in_catalog, catalog_id}}
      entry -> {:ok, entry}
    end
  end

  defp build_model(entry) do
    case ModelFactory.build(entry) do
      {:ok, model} ->
        {:ok, {entry, model}}

      {:error, {:unsupported_provider, provider}} ->
        {:error, {:no_adapter_for_provider, provider}}

      {:error, %Ecto.Changeset{errors: errors}} ->
        {:error, {:invalid_model_params, errors}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- the actual call: prompt, invoke, classify, validate, stamp ---

  defp call_model(role, iteration, %{view: view} = _context, entry, model) do
    request_text = build_request_text(role, iteration, view)

    chain_result =
      %{llm: with_provider_req_opts(model)}
      |> LLMChain.new!()
      |> LLMChain.add_message(Message.new_user!(request_text))
      |> LLMChain.run()

    handle_chain_result(chain_result, role, entry)
  rescue
    exception ->
      {:error, {:unclassified_provider_failure, inspect(exception.__struct__)}}
  end

  defp with_provider_req_opts(model) do
    case Application.get_env(:kapelle, :product_provider_req_opts) do
      nil -> model
      opts -> %{model | req_opts: opts}
    end
  end

  defp handle_chain_result({:ok, chain}, role, entry) do
    case ChainResult.to_string(chain) do
      {:ok, text} -> build_success(text, role, entry, chain)
      {:error, _chain, %LangChainError{} = error} -> classify_error(error)
    end
  end

  defp handle_chain_result({:error, _chain, %LangChainError{} = error}, _role, _entry) do
    classify_error(error)
  end

  defp build_success(text, role, entry, chain) do
    kind = kind_for_role(role)

    with {:ok, doc} <- parse_response(text) do
      stamped = stamp_provenance(doc, role, entry)

      case Validator.validate(kind, stamped) do
        :ok -> {:ok, stamped, call_meta(entry, chain)}
        {:error, reason} -> {:error, {:invalid_artifact, {:schema_invalid, reason}}}
      end
    end
  end

  # "не разобрано" (BEH-13): StrictParse itself never got a document.
  # `ContentPart.parts_to_string/2` returns `nil` (not `""`) for an
  # assistant message with no text content at all — an empty live
  # response is exactly as unparseable as one made of empty text.
  defp parse_response(nil), do: parse_response("")

  defp parse_response(text) do
    case StrictParse.parse(text) do
      {:ok, doc} -> {:ok, doc}
      {:error, reason} -> {:error, {:invalid_artifact, {:parse_failed, reason}}}
    end
  end

  defp stamp_provenance(doc, role, entry) do
    doc
    |> Map.put("produced_by", %{
      "kind" => "agent",
      "id" => Atom.to_string(role),
      "model" => entry.id,
      "prompt_version" => prompt_version(role)
    })
    |> Map.put("produced_at", StageShell.now_iso())
  end

  defp call_meta(entry, chain) do
    %{model_id: entry.id, tokens: tokens_from_usage(TokenUsage.get(chain.last_message))}
  end

  defp tokens_from_usage(nil), do: nil

  defp tokens_from_usage(%TokenUsage{input: input, output: output}) do
    %{input: input, output: output, total: total(input, output)}
  end

  defp total(input, output) when is_integer(input) and is_integer(output), do: input + output
  defp total(_input, _output), do: nil

  defp kind_for_role(:researcher), do: :research_pack
  defp kind_for_role(:creator), do: :concept_draft

  defp prompt_version(:researcher), do: "researcher/v1"
  defp prompt_version(:creator), do: "creator/v1"

  # --- provider failure classification (design doc Q-05) ---

  @infrastructure_types ~w(
    timeout retries_exceeded
    overloaded overloaded_error
    rate_limited rate_limit_exceeded too_many_requests
  )

  defp classify_error(%LangChainError{} = error) do
    status = recoverable_status(error)

    cond do
      transport_error?(error) -> {:error, {:infrastructure, provider_error(error)}}
      status in [401, 403] -> {:error, provider_auth_failed(error)}
      is_integer(status) and status >= 500 -> {:error, {:infrastructure, provider_error(error)}}
      status == 429 -> {:error, {:infrastructure, provider_error(error)}}
      status == 400 -> {:error, {:domain, provider_error(error)}}
      error.type in @infrastructure_types -> {:error, {:infrastructure, provider_error(error)}}
      error.type == "authentication_error" -> {:error, provider_auth_failed(error)}
      error.type == "invalid_request_error" -> {:error, {:domain, provider_error(error)}}
      true -> {:error, {:unclassified_provider_failure, error.type || "unknown"}}
    end
  end

  defp transport_error?(%LangChainError{original: %Req.TransportError{}}), do: true
  defp transport_error?(%LangChainError{original: {:error, %Req.TransportError{}}}), do: true
  defp transport_error?(_error), do: false

  defp recoverable_status(%LangChainError{original: %Req.Response{status: status}}), do: status

  defp recoverable_status(%LangChainError{original: {:ok, %Req.Response{status: status}}}),
    do: status

  defp recoverable_status(%LangChainError{original: %{status: status}})
       when is_integer(status),
       do: status

  defp recoverable_status(_error), do: nil

  defp provider_error(%LangChainError{type: type, message: message}) do
    {:provider_error, type || "unknown", message || ""}
  end

  defp provider_auth_failed(%LangChainError{type: type, message: message}) do
    {:provider_auth_failed, type || "unknown", message || ""}
  end

  # --- request assembly (design doc Q-07; exact wording is out of scope) ---

  @prompt_dirs %{researcher: "researcher", creator: "creator"}

  defp build_request_text(role, iteration, view) do
    """
    #{load_template(role)}

    ## Response schema (JSON Schema)

    #{schema_json(role)}

    ## Context

    #{Jason.encode!(request_context(role, iteration, view))}
    """
  end

  defp load_template(role) do
    Application.app_dir(:kapelle, "priv/prompts/product/#{Map.fetch!(@prompt_dirs, role)}/v1.md")
    |> File.read!()
  end

  defp schema_json(role) do
    role
    |> kind_for_role()
    |> Contracts.dir!()
    |> Path.join("schema.json")
    |> File.read!()
  end

  defp request_context(role, iteration, view) do
    %{
      "idea" => view.idea,
      "iteration" => iteration,
      "research_packs" => view.research_packs,
      "concept_drafts" => view.concept_drafts
    }
    |> maybe_put_research_pack_id(role, iteration, view)
  end

  defp maybe_put_research_pack_id(context, :creator, iteration, view) do
    Map.put(context, "research_pack_id", get_in(view.research_packs, [iteration, "id"]))
  end

  defp maybe_put_research_pack_id(context, :researcher, _iteration, _view), do: context
end
