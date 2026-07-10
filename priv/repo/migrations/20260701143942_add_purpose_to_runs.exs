defmodule Haven.Repo.Migrations.AddPurposeToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :purpose, :text, null: false, default: "work"
    end

    create index(:runs, [:purpose])

    execute(
      """
      UPDATE runs
      SET purpose = 'diagnostic'
      WHERE title LIKE 'Agent preflight:%'
         OR title LIKE 'Agent probe:%'
      """,
      """
      UPDATE runs
      SET purpose = 'work'
      WHERE purpose = 'diagnostic'
      """
    )
  end
end
