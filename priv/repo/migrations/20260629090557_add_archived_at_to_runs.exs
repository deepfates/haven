defmodule Haven.Repo.Migrations.AddArchivedAtToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :archived_at, :utc_datetime
    end

    create index(:runs, [:archived_at])
  end
end
