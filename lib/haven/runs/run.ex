defmodule Haven.Runs.Run do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "runs" do
    field :title, :string
    field :workspace, :string
    field :agent, :string
    field :status, :string, default: "idle"
    field :agent_session_id, :string

    has_many :events, Haven.Events.Event

    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [:title, :workspace, :agent, :status, :agent_session_id])
    |> validate_required([:title, :workspace, :agent, :status])
  end
end
