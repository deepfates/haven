defmodule Haven.Repo.Migrations.CreateAgentConfigs do
  use Ecto.Migration

  def change do
    create table(:agent_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key, :text, null: false
      add :executable, :text, null: false
      add :args, :map, null: false, default: %{"items" => []}
      add :cwd, :text
      add :env, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:agent_configs, [:key])
  end
end
