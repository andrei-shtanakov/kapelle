defmodule Kapelle.Executor.Result do
  @moduledoc """
  Contract struct emitted by `Kapelle.Executor.Adapter.execute/2`.

  Mirrors spec-runner exit codes: `:pass` (0), `:fail` (1), `:error` (2).

  `target` and `rejected` are populated by
  `Kapelle.Executor.FallbackResolver` when a catalog entry's `fallback`
  chain is walked: `target` is the catalog id that actually served the
  request, and `rejected` is the ordered list of `{id, reason}` pairs for
  every earlier target that errored. A `Result` produced without going
  through fallback resolution leaves both at their defaults.
  """

  @enforce_keys [:task_id, :status]
  defstruct [:task_id, :status, :output, :duration_ms, artifacts: [], target: nil, rejected: []]

  @type status :: :pass | :fail | :error

  @type t :: %__MODULE__{
          task_id: String.t(),
          status: status(),
          output: term(),
          duration_ms: non_neg_integer() | nil,
          artifacts: list(),
          target: String.t() | nil,
          rejected: [{String.t(), term()}]
        }

  @valid_statuses [:pass, :fail, :error]

  @doc """
  Builds a `Result`, raising `ArgumentError` if a required key is missing,
  `attrs` has an unknown key, `status` is not one of
  `#{inspect(@valid_statuses)}`, `artifacts` is not a list, or `rejected`
  is not a list.
  """
  @spec new!(map()) :: t()
  def new!(attrs) when is_map(attrs) do
    __MODULE__
    |> build!(attrs)
    |> validate_status!()
    |> validate_artifacts!()
    |> validate_rejected!()
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

  defp validate_rejected!(%__MODULE__{rejected: rejected} = result) when is_list(rejected) do
    result
  end

  defp validate_rejected!(%__MODULE__{rejected: rejected}) do
    raise ArgumentError, "rejected must be a list, got: #{inspect(rejected)}"
  end
end
