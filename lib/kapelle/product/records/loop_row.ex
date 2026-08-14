defmodule Kapelle.Product.Records.LoopRow do
  @moduledoc """
  Ecto schema for the `product_loops` table: a loop's configuration plus
  a best-effort projection of its latest producer-format loop-state
  document (design doc §5; owner's loop-state-leaves-the-store decision,
  2026-08-14). `latest_state` is deletable/reconstructible by definition
  — it is not an authoritative artifact and carries no monotonic
  revision of its own. `status`/`stop_reason` are this codebase's own
  loop lifecycle, driven by `Kapelle.Product.Loops.set_status/3`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(running ready needs_human failed)

  @primary_key {:loop_id, :string, autogenerate: false}

  schema "product_loops" do
    field :idea_identity, :string
    field :proposal_id, :string
    field :exchange_log_id, :string
    field :max_iterations, :integer
    field :agent, :string
    field :status, :string, default: "running"
    field :stop_reason, :string
    field :latest_state, :map

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          loop_id: String.t() | nil,
          idea_identity: String.t() | nil,
          proposal_id: String.t() | nil,
          exchange_log_id: String.t() | nil,
          max_iterations: integer() | nil,
          agent: String.t() | nil,
          status: String.t() | nil,
          stop_reason: String.t() | nil,
          latest_state: map() | nil
        }

  @doc """
  Builds a changeset for inserting a `LoopRow`, requiring the config
  fields and mapping a duplicate `loop_id` onto the same unique
  constraint the race path in `Kapelle.Product.Loops.create/1` classifies
  as `:already_initialized`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :loop_id,
      :idea_identity,
      :proposal_id,
      :exchange_log_id,
      :max_iterations,
      :agent,
      :status,
      :stop_reason,
      :latest_state
    ])
    |> validate_required([
      :loop_id,
      :idea_identity,
      :proposal_id,
      :exchange_log_id,
      :max_iterations,
      :agent
    ])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:loop_id, name: :product_loops_pkey)
  end
end
