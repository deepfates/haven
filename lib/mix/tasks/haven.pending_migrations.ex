defmodule Mix.Tasks.Haven.PendingMigrations do
  use Mix.Task

  @shortdoc "Fails if any configured repo has pending migrations"

  @moduledoc """
  Fails when any configured Ecto repo has pending migrations in the current Mix
  environment.

  Use this before browser/runtime verification against the dev server:

      MIX_ENV=dev mix haven.pending_migrations

  """

  @requirements ["app.config"]

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    repos = Application.fetch_env!(:haven, :ecto_repos)

    pending =
      repos
      |> Enum.flat_map(&pending_for_repo/1)

    case pending do
      [] ->
        Mix.shell().info("No pending migrations.")

      migrations ->
        Enum.each(migrations, fn {repo, version, name} ->
          Mix.shell().error("#{inspect(repo)} has pending migration #{version} #{name}")
        end)

        Mix.raise("Pending migrations found.")
    end
  end

  defp pending_for_repo(repo) do
    repo
    |> Ecto.Migrator.migrations()
    |> Enum.flat_map(fn
      {:down, version, name} -> [{repo, version, name}]
      _migration -> []
    end)
  end
end
