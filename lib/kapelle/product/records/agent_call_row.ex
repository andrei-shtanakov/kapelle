defmodule Kapelle.Product.Records.AgentCallRow do
  @moduledoc """
  Ecto schema for `product_agent_calls` (design doc Q-03): the durable
  usage carrier, append-only, one row per attempted live-agent call.
  `tokens_total` is nullable — `nil` means the attempt did not report
  usage, never a silent zero (`Kapelle.Product.RunVerdict`'s three cost
  states).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "product_agent_calls" do
    field :loop_id, :string
    field :iteration, :integer
    field :role, :string
    field :model_id, :string
    field :tokens_input, :integer
    field :tokens_output, :integer
    field :tokens_total, :integer

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{
          loop_id: String.t() | nil,
          iteration: integer() | nil,
          role: String.t() | nil,
          model_id: String.t() | nil,
          tokens_input: integer() | nil,
          tokens_output: integer() | nil,
          tokens_total: integer() | nil,
          inserted_at: DateTime.t() | nil
        }

  @doc "Builds a changeset for inserting one call-attempt row."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :loop_id,
      :iteration,
      :role,
      :model_id,
      :tokens_input,
      :tokens_output,
      :tokens_total
    ])
    |> validate_required([:loop_id, :iteration, :role])
  end
end
