defmodule Haven.Repo.Migrations.CreatePermissionAudits do
  use Ecto.Migration

  def change do
    create table(:permission_audits, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false
      add :request_id, :integer, null: false
      add :kind, :string, null: false
      add :title, :string
      add :tool_call_id, :string
      add :status, :string, null: false, default: "pending"
      add :raw_input, :map
      add :options, :map
      add :selected_option_id, :string
      add :outcome, :string
      add :actor, :string
      add :reason, :string
      add :resolved_at, :utc_datetime

      timestamps(type: :utc_datetime_usec)
    end

    create index(:permission_audits, [:run_id, :inserted_at])
    create index(:permission_audits, [:run_id, :request_id, :status])
  end
end
