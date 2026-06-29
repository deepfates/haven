defmodule Haven.Repo.Migrations.CreateTerminalSessions do
  use Ecto.Migration

  def change do
    create table(:terminal_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false
      add :terminal_id, :text, null: false
      add :command, :text, null: false
      add :args, :map, null: false, default: %{"items" => []}
      add :cwd, :text, null: false
      add :executable, :text
      add :env_keys, :map, null: false, default: %{"items" => []}
      add :os_pid, :integer
      add :status, :text, null: false, default: "running"
      add :exit_status, :integer
      add :output_bytes, :integer, null: false, default: 0
      add :output_preview, :text, null: false, default: ""
      add :output_truncated, :boolean, null: false, default: false
      add :killed_at, :utc_datetime
      add :released_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:terminal_sessions, [:run_id, :terminal_id])
    create index(:terminal_sessions, [:run_id])
    create index(:terminal_sessions, [:status])
  end
end
