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

  defp outside_workspace_error(path) do
    ACP.Error.invalid_params()
    |> ACP.Error.with_data(%{"path" => path, "reason" => "outside_workspace"})
  end

  defp file_error(message, path, reason) do
    %{ACP.Error.internal_error() | message: message}
    |> ACP.Error.with_data(%{"path" => path, "reason" => inspect(reason)})
  end
end
