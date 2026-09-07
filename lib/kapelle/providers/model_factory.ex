defmodule Kapelle.Providers.ModelFactory do
  @moduledoc """
  Builds a langchain chat model struct from a catalog id
  (`"<provider>@<model>"`), resolved via `Kapelle.Providers.Catalog`.
  """

  alias Kapelle.Providers.Catalog
  alias LangChain.ChatModels.ChatAnthropic

  @doc """
  Builds the langchain chat model for `id` — either a catalog id string
  (looked up via `Catalog.get/1`) or an already-resolved
  `Kapelle.Providers.Catalog.Entry` struct, used as-is with no catalog
  lookup at all. The struct form lets a caller that already loaded the
  catalog itself (e.g. from a non-default path) build the model from
  that exact entry, rather than this function re-reading the catalog
  from its own default location.

  Returns `{:ok, model}`, or `{:error, reason}` if `id` is unknown or
  malformed (see `Catalog.get/1`), the entry's provider has no langchain
  adapter here yet (`{:error, {:unsupported_provider, provider}}`), or the
  entry's params fail the model's own validation
  (`{:error, %Ecto.Changeset{}}`).
  """
  @spec build(term() | Catalog.Entry.t()) :: {:ok, struct()} | {:error, term()}
  def build(%Catalog.Entry{} = entry), do: build_model(entry)

  def build(id) do
    with {:ok, entry} <- Catalog.get(id) do
      build_model(entry)
    end
  end

  defp build_model(%{provider: "anthropic", model: model, params: params}) do
    ChatAnthropic.new(Map.put(params, "model", model))
  end

  defp build_model(%{provider: provider}) do
    {:error, {:unsupported_provider, provider}}
  end
end
