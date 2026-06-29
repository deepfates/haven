defmodule Haven.Repo.Migrations.CreateFileChanges do
  use Ecto.Migration

  def change do
    create table(:file_changes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:runs, type: :binary_id, on_delete: :delete_all), null: false
      add :change_id, :text, null: false
      add :path, :text, null: false
      add :resolved_path, :text
      add :status, :text, null: false, default: "pending"
      add :diff_kind, :text, null: false, default: "unknown"
      add :bytes, :integer, null: false, default: 0
      add :existing_bytes, :integer
      add :content_preview, :text, null: false, default: ""
      add :content_preview_limit, :integer, null: false, default: 4000
      add :content_truncated, :boolean, null: false, default: false
      add :diff_preview, :text, null: false, default: ""
      add :diff_preview_limit, :integer, null: false, default: 8000
      add :diff_truncated, :boolean, null: false, default: false
      add :error, :map

      timestamps(type: :utc_datetime)
    end

    create unique_index(:file_changes, [:run_id, :change_id])
    create index(:file_changes, [:run_id])
    create index(:file_changes, [:status])
  end
end
