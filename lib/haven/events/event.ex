defmodule Haven.Events.Event do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "events" do
    field :seq, :integer
    field :type, :string
    field :payload, :map, default: %{}

    belongs_to :run, Haven.Runs.Run

    timestamps(type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:run_id, :seq, :type, :payload])
    |> validate_required([:run_id, :seq, :type, :payload])
    |> unique_constraint([:run_id, :seq])
  end
end
