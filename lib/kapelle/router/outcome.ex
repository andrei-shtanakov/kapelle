defmodule Kapelle.Router.Outcome do
  @moduledoc """
  Typed router feedback derived from a terminal `Kapelle.Evaluator.Verdict`.

  Closes the `decision_id → verdict → router outcome` loop (REQ-102): once a
  `Verdict` is final, `from_verdict/1` reduces it to a binary `:success` /
  `:failure` signal the router can use for target reliability, without
  callers needing to know how a score maps to that signal.
  """

  alias Kapelle.Evaluator.Verdict

  @enforce_keys [:decision_id, :task_id, :type]
  defstruct [:decision_id, :task_id, :type]

  @type type :: :success | :failure

  @type t :: %__MODULE__{
          decision_id: String.t(),
          task_id: String.t(),
          type: type()
        }

  @doc """
  Builds an `Outcome`, raising `ArgumentError` if a required key is missing,
  `attrs` has an unknown key, or `type` is not `:success` or `:failure`.
  """
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    __MODULE__
    |> build!(attrs)
    |> validate_type!()
  end

  @doc """
  Derives an `Outcome` from a terminal `Verdict`: `:success` if
  `total_score` is positive, `:failure` otherwise (a fully-failed result
  scores `0.0`, per `Evaluator.FakeJudge`'s `@score_by_status`).
  """
  @spec from_verdict(Verdict.t()) :: t()
  def from_verdict(%Verdict{} = verdict) do
    new!(%{
      decision_id: verdict.decision_id,
      task_id: verdict.task_id,
      type: if(verdict.total_score > 0.0, do: :success, else: :failure)
    })
  end

  defp build!(module, attrs) do
    struct!(module, attrs)
  rescue
    KeyError ->
      reraise ArgumentError.exception("unknown key for #{inspect(module)}"), __STACKTRACE__
  end

  defp validate_type!(%__MODULE__{type: type} = outcome) when type in [:success, :failure] do
    outcome
  end

  defp validate_type!(%__MODULE__{type: type}) do
    raise ArgumentError, "type must be :success or :failure, got: #{inspect(type)}"
  end
end
