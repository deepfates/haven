defmodule Haven.Agents do
  @moduledoc """
  Resolves run agent identifiers into executable ACP transports.

  `stub-acp` is built in for deterministic local validation. Additional agents
  can be configured with:

      config :haven, :agents, %{
        "my-agent" => %{executable: "/path/to/agent", args: ["--workspace", "{workspace}"]}
      }
  """

  @type command :: %{
          executable: String.t(),
          args: [String.t()],
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
    with {:ok, executable} <- fetch_string(spec, :executable),
         {:ok, args} <- fetch_args(spec, workspace) do
      {:ok, %{executable: executable, args: args, label: agent}}
    end
  end

  defp command_from_spec(_agent, _spec, _workspace), do: {:error, :invalid_agent_spec}

  defp fetch_string(spec, key) do
    case Map.get(spec, key) || Map.get(spec, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_agent_field, key}}
    end
  end

  defp fetch_args(spec, workspace) do
    args = Map.get(spec, :args) || Map.get(spec, "args") || []

    if is_list(args) and Enum.all?(args, &is_binary/1) do
      {:ok, Enum.map(args, &String.replace(&1, "{workspace}", workspace))}
    else
      {:error, {:invalid_agent_field, :args}}
    end
  end
end
