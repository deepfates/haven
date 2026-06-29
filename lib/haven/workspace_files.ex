defmodule Haven.WorkspaceFiles do
  @moduledoc """
  File capability helpers scoped to a run workspace.
  """

  def read_text_file(workspace, request) do
    with {:ok, path} <- resolve_path(workspace, request.path),
         {:ok, content} <- File.read(path) do
      {:ok, slice_content(content, request.line, request.limit), path}
    else
      {:error, :outside_workspace} -> {:error, outside_workspace_error(request.path)}
      {:error, :enoent} -> {:error, ACP.Error.resource_not_found(request.path)}
      {:error, reason} -> {:error, file_error("Could not read text file", request.path, reason)}
    end
  end

  def write_text_file(workspace, request) do
    with {:ok, path} <- resolve_path(workspace, request.path),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, request.content) do
      {:ok, path}
    else
      {:error, :outside_workspace} -> {:error, outside_workspace_error(request.path)}
      {:error, reason} -> {:error, file_error("Could not write text file", request.path, reason)}
    end
  end

  def write_text_file_diff_preview(workspace, request, limit) do
    with {:ok, path} <- resolve_path(workspace, request.path) do
      existing_content =
        case File.read(path) do
          {:ok, content} -> content
          {:error, :enoent} -> nil
          {:error, _reason} -> nil
        end

      diff = render_write_diff(request.path, existing_content, request.content)

      %{
        "diff_kind" => if(is_nil(existing_content), do: "create", else: "modify"),
        "diff_preview" => String.slice(diff, 0, limit),
        "diff_preview_limit" => limit,
        "diff_truncated" => String.length(diff) > limit,
        "existing_bytes" => if(is_nil(existing_content), do: 0, else: byte_size(existing_content))
      }
    else
      {:error, :outside_workspace} ->
        %{
          "diff_error" => "outside_workspace",
          "diff_kind" => "unknown",
          "diff_preview" => "",
          "diff_preview_limit" => limit,
          "diff_truncated" => false,
          "existing_bytes" => nil
        }
    end
  end

  def path_in_scopes?(workspace, path, scopes)
  def path_in_scopes?(_workspace, _path, nil), do: true

  def path_in_scopes?(workspace, path, scopes) when is_list(scopes) do
    with {:ok, resolved_path} <- resolve_path(workspace, path) do
      Enum.any?(scopes, &path_in_scope?(workspace, resolved_path, &1))
    else
      {:error, :outside_workspace} -> false
    end
  end

  def path_in_scopes?(_workspace, _path, _scopes), do: false

  defp resolve_path(workspace, path) when is_binary(path) do
    workspace = Path.expand(workspace)

    path =
      case Path.type(path) do
        :absolute -> Path.expand(path)
        _ -> Path.expand(path, workspace)
      end

    if path == workspace or String.starts_with?(path, workspace <> "/") do
      {:ok, path}
    else
      {:error, :outside_workspace}
    end
  end

  defp resolve_path(_workspace, _path), do: {:error, :outside_workspace}

  defp path_in_scope?(_workspace, _resolved_path, scope) when scope in ["*", "**"], do: true

  defp path_in_scope?(workspace, resolved_path, scope) when is_binary(scope) do
    case resolve_path(workspace, scope) do
      {:ok, scope_path} ->
        resolved_path == scope_path or String.starts_with?(resolved_path, scope_path <> "/")

      {:error, :outside_workspace} ->
        false
    end
  end

  defp path_in_scope?(_workspace, _resolved_path, _scope), do: false

  defp slice_content(content, nil, nil), do: content

  defp slice_content(content, line, limit) do
    line = if is_integer(line) and line > 0, do: line, else: 1

    content
    |> String.split("\n", trim: false)
    |> Enum.drop(line - 1)
    |> limit_lines(limit)
    |> Enum.join("\n")
  end

  defp limit_lines(lines, limit) when is_integer(limit) and limit >= 0,
    do: Enum.take(lines, limit)

  defp limit_lines(lines, _limit), do: lines

  defp render_write_diff(path, nil, content) do
    additions =
      content
      |> diff_lines()
      |> Enum.map_join("", &"+#{&1}")

    """
    --- /dev/null
    +++ #{path}
    #{additions}\
    """
  end

  defp render_write_diff(path, existing_content, content) do
    deletions =
      existing_content
      |> diff_lines()
      |> Enum.map_join("", &"-#{&1}")

    additions =
      content
      |> diff_lines()
      |> Enum.map_join("", &"+#{&1}")

    """
    --- #{path}
    +++ #{path}
    #{deletions}#{additions}\
    """
  end

  defp diff_lines(content), do: String.split(content, "\n", trim: false) |> attach_newlines()

  defp attach_newlines([]), do: []
  defp attach_newlines([""]), do: []

  defp attach_newlines(lines) do
    last_index = length(lines) - 1

    lines
    |> Enum.with_index()
    |> Enum.map(fn
      {"", ^last_index} -> ""
      {line, _index} -> line <> "\n"
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp outside_workspace_error(path) do
    ACP.Error.invalid_params()
    |> ACP.Error.with_data(%{"path" => path, "reason" => "outside_workspace"})
  end

  defp file_error(message, path, reason) do
    %{ACP.Error.internal_error() | message: message}
    |> ACP.Error.with_data(%{"path" => path, "reason" => inspect(reason)})
  end
end
