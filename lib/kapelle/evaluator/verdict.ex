defmodule Kapelle.Evaluator.Verdict do
  @moduledoc """
  Contract struct emitted by `Kapelle.Evaluator.Judge.evaluate/2`.

  `score_components` must never be dropped by any function that produces or
  passes along a `Verdict` (the ATP `total_score`-only gap lesson).
  """

  @enforce_keys [:decision_id, :task_id, :total_score]
  defstruct [:decision_id, :task_id, :total_score, score_components: %{}]

  @type t :: %__MODULE__{
          decision_id: String.t(),
          task_id: String.t(),
          total_score: number(),
          score_components: map()
        }

  @doc """
  Builds a `Verdict`, raising `ArgumentError` if a required key is missing,
  `attrs` has an unknown key, or `total_score` is not a number.
  """
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    __MODULE__
    |> build!(attrs)
    |> validate_total_score!()
  end

  defp build!(module, attrs) do
    struct!(module, attrs)
  rescue
    KeyError ->
      reraise ArgumentError.exception("unknown key for #{inspect(module)}"), __STACKTRACE__
  end

  defp validate_total_score!(%__MODULE__{total_score: total_score} = verdict)
       when is_number(total_score) do
    verdict
  end

  defp validate_total_score!(%__MODULE__{}) do
    raise ArgumentError, "total_score must be a number"
  end
end
