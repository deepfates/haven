defmodule Haven.Workspaces.Workspace do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workspaces" do
    field :name, :string
    field :path, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name, :path])
    |> update_change(:name, &trim_string/1)
    |> update_change(:path, &normalize_path/1)
    |> validate_required([:name, :path])
    |> validate_change(:path, fn :path, path ->
      if File.dir?(path), do: [], else: [path: "must be an existing directory"]
    end)
    |> unique_constraint(:path)
  end

  defp normalize_path(path) when is_binary(path) do
    case String.trim(path) do
      "" -> ""
      trimmed -> Path.expand(trimmed)
    end
  end

  defp normalize_path(path), do: path

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(value), do: value
end
