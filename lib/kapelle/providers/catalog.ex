defmodule Kapelle.Providers.Catalog do
  @moduledoc """
  Loads and queries the provider/model catalog declared in
  `priv/catalog/models.toml`. Stateless: every call re-reads and
  re-validates the file (no runtime hot-reload; see design NFR notes).
  """

  alias Kapelle.Providers.Catalog.Entry

  @doc """
  Parses and validates the catalog TOML file at `path`, defaulting to
  `priv/catalog/models.toml`.

  Returns `{:ok, entries}` on success, or `{:error, reason}` if the file is
  missing, contains invalid TOML syntax, has an unexpected top-level shape,
  or any entry is missing a required field. Validation is all-or-nothing:
  the first invalid entry short-circuits the whole load.
  """
  @spec load(Path.t()) :: {:ok, [Entry.t()]} | {:error, term()}
  def load(path \\ default_path()) do
    with {:ok, path} <- ensure_file_exists(path),
         {:ok, decoded} <- decode_toml(path),
         {:ok, models} <- validate_shape(decoded),
         {:ok, entries} <- build_entries(models),
         :ok <- validate_fallbacks(entries) do
      {:ok, entries}
    end
  end

  @doc """
  Returns all catalog entries.

  Delegates to `load/1`; see its docs for the error cases.
  """
  @spec list() :: {:ok, [Entry.t()]} | {:error, term()}
  def list, do: load()

  @doc """
  Fetches a single catalog entry by its `"<provider>@<model>"` id.

  Returns `{:ok, entry}` if found, `{:error, {:unknown_model_id, id}}`
  if no entry matches, or `{:error, {:invalid_model_id, id}}` if `id` is
  not a string. Never raises and never returns `nil`.
  """
  @spec get(term()) :: {:ok, Entry.t()} | {:error, term()}
  def get(id) when is_binary(id) do
    with {:ok, entries} <- load() do
      case Enum.find(entries, &(&1.id == id)) do
        nil -> {:error, {:unknown_model_id, id}}
        entry -> {:ok, entry}
      end
    end
  end

  def get(id), do: {:error, {:invalid_model_id, id}}

  defp default_path do
    Application.app_dir(:kapelle, "priv/catalog/models.toml")
  end

  defp ensure_file_exists(path) do
    if File.exists?(path) do
      {:ok, path}
    else
      {:error, {:catalog_file_not_found, path}}
    end
  end

  defp decode_toml(path) do
    case Toml.decode_file(path) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_toml, toml_error_message(reason)}}
    end
  end

  defp toml_error_message({:invalid_toml, message}) when is_binary(message), do: message
  defp toml_error_message(message) when is_binary(message), do: message

  defp toml_error_message(reason) do
    if is_exception(reason), do: Exception.message(reason), else: inspect(reason)
  end

  defp validate_shape(%{"models" => models}) when is_list(models), do: {:ok, models}
  defp validate_shape(decoded), do: {:error, {:invalid_catalog_shape, decoded}}

  defp build_entries(models) do
    models
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {model, index}, {:ok, acc} ->
      case build_entry(model, index) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp build_entry(model, index) do
    with {:ok, provider} <- fetch_required_string(model, "provider", :provider, index),
         {:ok, model_name} <- fetch_required_string(model, "model", :model, index),
         {:ok, params} <- fetch_params(model, index),
         {:ok, fallback} <- fetch_fallback(model, index) do
      {:ok,
       %Entry{
         id: "#{provider}@#{model_name}",
         provider: provider,
         model: model_name,
         params: params,
         fallback: fallback
       }}
    end
  end

  defp fetch_required_string(model, key, field, index) do
    case Map.get(model, key) do
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:invalid_entry, index, :missing_field, field}}
    end
  end

  defp fetch_params(model, index) do
    case Map.get(model, "params", %{}) do
      params when is_map(params) -> {:ok, params}
      _other -> {:error, {:invalid_entry, index, :invalid_field, :params}}
    end
  end

  defp fetch_fallback(model, index) do
    case Map.get(model, "fallback", []) do
      fallback when is_list(fallback) ->
        if Enum.all?(fallback, &is_binary/1) do
          {:ok, fallback}
        else
          {:error, {:invalid_entry, index, :invalid_field, :fallback}}
        end

      _other ->
        {:error, {:invalid_entry, index, :invalid_field, :fallback}}
    end
  end

  defp validate_fallbacks(entries) do
    with :ok <- validate_unique_ids(entries) do
      ids = MapSet.new(entries, & &1.id)
      chains = Map.new(entries, &{&1.id, &1.fallback})

      with :ok <- validate_fallback_targets_known(entries, ids) do
        validate_fallback_acyclic(chains)
      end
    end
  end

  defp validate_unique_ids(entries) do
    entries
    |> Enum.frequencies_by(& &1.id)
    |> Enum.find(fn {_id, count} -> count > 1 end)
    |> case do
      nil -> :ok
      {id, _count} -> {:error, {:duplicate_id, id}}
    end
  end

  defp validate_fallback_targets_known(entries, ids) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case Enum.find(entry.fallback, &(not MapSet.member?(ids, &1))) do
        nil -> {:cont, :ok}
        unknown_target -> {:halt, {:error, {:unknown_fallback, entry.id, unknown_target}}}
      end
    end)
  end

  defp validate_fallback_acyclic(chains) do
    chains
    |> Map.keys()
    |> Enum.reduce_while(:ok, fn id, :ok ->
      case find_cycle(chains, id, [id]) do
        nil -> {:cont, :ok}
        cycle -> {:halt, {:error, {:fallback_cycle, cycle}}}
      end
    end)
  end

  defp find_cycle(chains, id, path) do
    chains
    |> Map.fetch!(id)
    |> Enum.find_value(fn target ->
      if target in path do
        Enum.reverse([target | path])
      else
        find_cycle(chains, target, [target | path])
      end
    end)
  end
end
