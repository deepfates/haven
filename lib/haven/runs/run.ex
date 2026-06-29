defmodule Haven.Runs.Run do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "runs" do
    field :title, :string
    field :workspace, :string
    field :agent, :string
    field :status, :string, default: "idle"
    field :agent_session_id, :string
    field :archived_at, :utc_datetime
    field :capability_policy, :map, default: %{}

    has_many :events, Haven.Events.Event
    has_many :terminal_sessions, Haven.TerminalSessions.TerminalSession

    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [:title, :workspace, :agent, :status, :agent_session_id, :capability_policy])
    |> update_change(:workspace, &normalize_workspace/1)
    |> update_change(:capability_policy, &normalize_capability_policy/1)
    |> validate_required([:title, :workspace, :agent, :status])
    |> validate_workspace()
  end

  def capability_policy(policy), do: normalize_capability_policy(policy)

  defp normalize_workspace(workspace) when is_binary(workspace) do
    case String.trim(workspace) do
      "" -> ""
      path -> Path.expand(path)
    end
  end

  defp validate_workspace(changeset) do
    validate_change(changeset, :workspace, fn :workspace, workspace ->
      if File.dir?(workspace) do
        []
      else
        [workspace: "must be an existing directory"]
      end
    end)
  end

  defp normalize_capability_policy(policy) when is_map(policy) do
    %{
      "file_read" =>
        capability_decision(Map.get(policy, "file_read", Map.get(policy, :file_read))),
      "file_write" =>
        capability_decision(Map.get(policy, "file_write", Map.get(policy, :file_write))),
      "terminal_create" =>
        terminal_capability_decision(
          Map.get(policy, "terminal_create", Map.get(policy, :terminal_create)),
          "allow"
        )
    }
    |> put_path_scope(policy, "file_read_paths")
    |> put_path_scope(policy, "file_write_paths")
  end

  defp normalize_capability_policy(_policy), do: normalize_capability_policy(%{})

  defp capability_decision(value, default \\ "ask")
  defp capability_decision(value, _default) when value in ["ask", "allow", "deny"], do: value
  defp capability_decision(_value, default), do: default

  defp terminal_capability_decision(value, _default) when value in ["ask", "allow", "deny"],
    do: value

  defp terminal_capability_decision(_value, default), do: default

  defp put_path_scope(normalized, policy, key) do
    atom_key = path_scope_atom_key(key)

    cond do
      Map.has_key?(policy, key) ->
        Map.put(normalized, key, normalize_path_scope(Map.get(policy, key)))

      Map.has_key?(policy, atom_key) ->
        Map.put(normalized, key, normalize_path_scope(Map.get(policy, atom_key)))

      true ->
        normalized
    end
  end

  defp path_scope_atom_key("file_read_paths"), do: :file_read_paths
  defp path_scope_atom_key("file_write_paths"), do: :file_write_paths

  defp normalize_path_scope(paths) when is_list(paths) do
    paths
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_path_scope(path) when is_binary(path), do: normalize_path_scope([path])
  defp normalize_path_scope(_paths), do: []
end
