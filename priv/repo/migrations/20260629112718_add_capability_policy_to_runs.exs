defmodule Haven.Repo.Migrations.AddCapabilityPolicyToRuns do
  use Ecto.Migration

  def change do
    alter table(:runs) do
      add :capability_policy, :map, null: false, default: %{}
    end
  end
end
