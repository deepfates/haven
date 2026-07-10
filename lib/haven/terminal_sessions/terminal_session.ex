defmodule Haven.TerminalSessions.TerminalSession do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "terminal_sessions" do
    field :terminal_id, :string
    field :command, :string
    field :args, :map, default: %{"items" => []}
    field :cwd, :string
    field :executable, :string
    field :env_keys, :map, default: %{"items" => []}
    field :os_pid, :integer
    field :status, :string, default: "running"
    field :exit_status, :integer
    field :output_bytes, :integer, default: 0
    field :output_preview, :string, default: ""
    field :output_truncated, :boolean, default: false
    field :killed_at, :utc_datetime
    field :released_at, :utc_datetime

    belongs_to :run, Haven.Runs.Run

    timestamps(type: :utc_datetime)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :run_id,
      :terminal_id,
      :command,
      :args,
      :cwd,
      :executable,
      :env_keys,
      :os_pid,
      :status,
      :exit_status,
      :output_bytes,
      :output_preview,
      :output_truncated,
      :killed_at,
      :released_at
    ])
    |> validate_required([:run_id, :terminal_id, :command, :args, :cwd, :env_keys, :status])
    |> validate_inclusion(:status, ["running", "exited", "killed", "released", "failed"])
    |> unique_constraint([:run_id, :terminal_id])
  end
end
