defmodule Kapelle.Router.Decision do
  @moduledoc """
  Contract struct emitted by `Kapelle.Router.Policy.route/2`.

  Immutable record of a routing decision: which task was routed to which
  provider/model target, and when.
  """

  @enforce_keys [:decision_id, :task_id, :target, :decided_at]
  defstruct [:decision_id, :task_id, :target, :decided_at, features: %{}]

  @type target :: %{provider: String.t(), model: String.t()}

  @type t :: %__MODULE__{
          decision_id: String.t(),
          task_id: String.t(),
          target: target(),
          decided_at: DateTime.t(),
          features: map()
        }

  @doc """
  Builds a `Decision`, raising `ArgumentError` if a required key is missing,
  `attrs` has an unknown key, `target` is not a
  `%{provider: String.t(), model: String.t()}` map with exactly those keys,
  or `features` is not a map.
  """
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    __MODULE__
    |> build!(attrs)
    |> validate_target!()
    |> validate_features!()
  end

  defp build!(module, attrs) do
    struct!(module, attrs)
  rescue
    KeyError ->
      reraise ArgumentError.exception("unknown key for #{inspect(module)}"), __STACKTRACE__
  end

  defp validate_target!(
         %__MODULE__{target: %{provider: provider, model: model} = target} = decision
       )
       when is_binary(provider) and is_binary(model) and map_size(target) == 2 do
    decision
  end

  defp validate_target!(%__MODULE__{}) do
    raise ArgumentError,
          "target must be a map with exactly string :provider and :model keys"
  end

  defp validate_features!(%__MODULE__{features: features} = decision) when is_map(features) do
    decision
  end

  defp validate_features!(%__MODULE__{features: features}) do
    raise ArgumentError, "features must be a map, got: #{inspect(features)}"
  end
end
