defmodule Kapelle.Executor.Result do
  @moduledoc """
  Contract struct emitted by `Kapelle.Executor.Adapter.execute/2`.

  Mirrors spec-runner exit codes: `:pass` (0), `:fail` (1), `:error` (2).
  """

  @enforce_keys [:task_id, :status]
  defstruct [:task_id, :status, :output, :duration_ms, artifacts: []]

  @type status :: :pass | :fail | :error

  @type t :: %__MODULE__{
          task_id: String.t(),
          status: status(),
          output: term(),
          duration_ms: non_neg_integer() | nil,
          artifacts: list()
        }

  @valid_statuses [:pass, :fail, :error]

  @doc """
  Builds a `Result`, raising `ArgumentError` if a required key is missing,
  `attrs` has an unknown key, `status` is not one of
  `#{inspect(@valid_statuses)}`, or `artifacts` is not a list.
  """
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    __MODULE__
    |> build!(attrs)
    |> validate_status!()
    |> validate_artifacts!()
  end

  defp build!(module, attrs) do
    struct!(module, attrs)
  rescue
    KeyError ->
      reraise ArgumentError.exception("unknown key for #{inspect(module)}"), __STACKTRACE__
  end

  defp validate_status!(%__MODULE__{status: status} = result) when status in @valid_statuses do
    result
  end

  defp validate_status!(%__MODULE__{status: status}) do
    raise ArgumentError,
          "status must be one of #{inspect(@valid_statuses)}, got: #{inspect(status)}"
  end

  defp validate_artifacts!(%__MODULE__{artifacts: artifacts} = result) when is_list(artifacts) do
    result
  end

  defp validate_artifacts!(%__MODULE__{artifacts: artifacts}) do
    raise ArgumentError, "artifacts must be a list, got: #{inspect(artifacts)}"
  end
end
