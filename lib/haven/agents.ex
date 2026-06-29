defmodule Haven.Agents do
  @moduledoc """
  Resolves run agent identifiers into executable ACP transports.

  `stub-acp` is built in for deterministic local validation. Additional agents
  can be configured with:

      config :haven, :agents, %{
        "my-agent" => %{
          executable: "/path/to/agent",
          args: ["--workspace", "{workspace}"],
          cwd: "{workspace}",
          env: %{"TOKEN" => "...", "WORKSPACE" => "{workspace}"}
        }
      }
  """

  import Bitwise

  @type command :: %{
          executable: String.t(),
          args: [String.t()],
          cwd: String.t() | nil,
          env: [{String.t(), String.t()}],
          label: String.t()
        }

  @spec available :: [{String.t(), String.t()}]
  def available do
    configured =
      configured_agents()
      |> Map.keys()
      |> Enum.reject(&(&1 == "stub-acp"))
      |> Enum.sort()
      |> Enum.map(&{&1, &1})

    [{"stub-acp", "stub-acp"} | configured]
  end

  @spec command(String.t(), String.t()) :: {:ok, command()} | {:error, term()}
  def command("stub-acp", workspace) do
    case System.find_executable("mix") do
      nil ->
        {:error, {:missing_executable, "mix"}}

      executable ->
        {:ok,
         %{
           executable: executable,
           args: ["run", "--no-compile", "--no-start", "priv/agent_stub.exs", workspace],
           cwd: nil,
           env: [],
           label: "stub-acp"
         }}
    end
  end

  def command(agent, workspace) when is_binary(agent) do
    case configured_agents()[agent] do
      nil -> {:error, {:unknown_agent, agent}}
      spec -> command_from_spec(agent, spec, workspace)
    end
  end

  defp configured_agents do
    Application.get_env(:haven, :agents, %{})
  end

  defp command_from_spec(agent, spec, workspace) when is_map(spec) do
    with {:ok, executable} <- fetch_executable(spec),
         {:ok, args} <- fetch_args(spec, workspace),
         {:ok, cwd} <- fetch_cwd(spec, workspace),
         {:ok, env} <- fetch_env(spec, workspace) do
      {:ok, %{executable: executable, args: args, cwd: cwd, env: env, label: agent}}
    end
  end

  defp command_from_spec(_agent, _spec, _workspace), do: {:error, :invalid_agent_spec}

  defp fetch_string(spec, key) do
    case Map.get(spec, key) || Map.get(spec, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_agent_field, key}}
    end
  end

  defp fetch_executable(spec) do
    with {:ok, executable} <- fetch_string(spec, :executable) do
      resolve_executable(executable)
    end
  end

  defp resolve_executable(executable) do
    cond do
      Path.type(executable) == :absolute and executable?(executable) ->
        {:ok, executable}

      Path.type(executable) == :absolute ->
        {:error, {:missing_executable, executable}}

      String.contains?(executable, "/") ->
        executable
        |> Path.expand()
        |> resolve_executable()

      resolved = System.find_executable(executable) ->
        {:ok, resolved}

      true ->
        {:error, {:missing_executable, executable}}
    end
  end

  defp executable?(path) do
    with true <- File.regular?(path),
         {:ok, stat} <- File.stat(path) do
      (stat.mode &&& 0o111) != 0
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp fetch_args(spec, workspace) do
    args = Map.get(spec, :args) || Map.get(spec, "args") || []

    if is_list(args) and Enum.all?(args, &is_binary/1) do
      {:ok, Enum.map(args, &String.replace(&1, "{workspace}", workspace))}
    else
      {:error, {:invalid_agent_field, :args}}
    end
  end

  defp fetch_cwd(spec, workspace) do
    case Map.get(spec, :cwd) || Map.get(spec, "cwd") do
      nil ->
        {:ok, nil}

      cwd when is_binary(cwd) and cwd != "" ->
        {:ok, String.replace(cwd, "{workspace}", workspace)}

      _ ->
        {:error, {:invalid_agent_field, :cwd}}
    end
  end

  defp fetch_env(spec, workspace) do
    env = Map.get(spec, :env) || Map.get(spec, "env") || []

    cond do
      is_map(env) ->
        env
        |> Map.to_list()
        |> normalize_env(workspace)

      is_list(env) ->
        normalize_env(env, workspace)

      true ->
        {:error, {:invalid_agent_field, :env}}
    end
  end

  defp normalize_env(env, workspace) do
    if Enum.all?(env, &valid_env_pair?/1) do
      {:ok,
       Enum.map(env, fn {name, value} ->
         {to_string(name), String.replace(value, "{workspace}", workspace)}
       end)
       |> Enum.sort_by(fn {name, _value} -> name end)}
    else
      {:error, {:invalid_agent_field, :env}}
    end
  end

  defp valid_env_pair?({name, value}) when is_binary(value) do
    (is_atom(name) or is_binary(name)) and to_string(name) != ""
  end

  defp valid_env_pair?(_pair), do: false
end
