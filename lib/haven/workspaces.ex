defmodule Haven.Workspaces do
  import Ecto.Query

  alias Haven.Repo
  alias Haven.Workspaces.Workspace

  def list_workspaces do
    Repo.all(from workspace in Workspace, order_by: [asc: workspace.name, asc: workspace.path])
  end

  def get_workspace(id), do: Repo.get(Workspace, id)

  def get_workspace!(id), do: Repo.get!(Workspace, id)

  def create_workspace(attrs) do
    %Workspace{}
    |> Workspace.changeset(attrs)
    |> Repo.insert()
  end

  def update_workspace(%Workspace{} = workspace, attrs) do
    workspace
    |> Workspace.changeset(attrs)
    |> Repo.update()
  end

  def delete_workspace(%Workspace{} = workspace) do
    Repo.delete(workspace)
  end
end
