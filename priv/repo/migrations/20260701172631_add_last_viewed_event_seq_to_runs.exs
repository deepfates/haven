defmodule Haven.Repo.Migrations.AddLastViewedEventSeqToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :last_viewed_event_seq, :integer, null: false, default: 0
    end

    execute(
      """
      UPDATE runs
      SET last_viewed_event_seq = COALESCE(
        (
          SELECT MAX(events.seq)
          FROM events
          WHERE events.run_id = runs.id
        ),
        0
      )
      """,
      """
      UPDATE runs
      SET last_viewed_event_seq = 0
      """
    )
  end
end
