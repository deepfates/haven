defmodule Haven.WorkspacesTest do
  use Haven.DataCase, async: false

  alias Haven.Workspaces

  @tag :tmp_dir
  test "creates normalized saved workspaces", %{tmp_dir: tmp_dir} do
    assert {:ok, workspace} =
             Workspaces.create_workspace(%{
               "name" => "  Repo  ",
               "path" => tmp_dir
             })

    assert workspace.name == "Repo"
    assert workspace.path == Path.expand(tmp_dir)
    assert Workspaces.list_workspaces() == [workspace]
  end

  test "rejects missing workspace directories" do
    missing = Path.join(System.tmp_dir!(), "haven-missing-saved-workspace")
    File.rm_rf!(missing)

    assert {:error, changeset} =
             Workspaces.create_workspace(%{
               "name" => "Missing",
               "path" => missing
             })

    assert %{path: ["must be an existing directory"]} = errors_on(changeset)
  end

  @tag :tmp_dir
  test "updates saved workspaces", %{tmp_dir: tmp_dir} do
    next_dir = Path.join(tmp_dir, "next")
    File.mkdir_p!(next_dir)

    assert {:ok, workspace} =
             Workspaces.create_workspace(%{
               "name" => "Before",
               "path" => tmp_dir
             })

    assert {:ok, updated} =
             Workspaces.update_workspace(workspace, %{
               "name" => "  After  ",
               "path" => next_dir
             })

    assert updated.id == workspace.id
    assert updated.name == "After"
    assert updated.path == Path.expand(next_dir)
    assert Workspaces.list_workspaces() == [updated]
  end

  @tag :tmp_dir
  test "deletes saved workspaces", %{tmp_dir: tmp_dir} do
    assert {:ok, workspace} =
             Workspaces.create_workspace(%{
               "name" => "Temporary",
               "path" => tmp_dir
             })

    assert {:ok, _workspace} = Workspaces.delete_workspace(workspace)
    assert Workspaces.list_workspaces() == []
  end
end
