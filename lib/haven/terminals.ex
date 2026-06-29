defmodule Haven.Terminals do
  @moduledoc """
  Minimal non-interactive terminal sessions for ACP terminal capability requests.
  """

  use GenServer

  defstruct [:port, :terminal_id, output: "", exit_status: nil, waiters: []]

  def start(opts), do: GenServer.start(__MODULE__, opts)
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def output(pid), do: GenServer.call(pid, :output, :infinity)
  def wait_for_exit(pid), do: GenServer.call(pid, :wait_for_exit, :infinity)
  def kill(pid), do: GenServer.call(pid, :kill, :infinity)
  def release(pid), do: GenServer.stop(pid, :normal)

  def command_options(workspace, request) do
    with {:ok, executable} <- resolve_executable(request.command),
         {:ok, cwd} <- resolve_cwd(workspace, request.cwd) do
      {:ok,
       [
         terminal_id: "term-#{System.unique_integer([:positive])}",
         executable: executable,
         args: request.args || [],
         cwd: cwd,
         env: env(request.env || [])
       ]}
    end
  end

  @impl true
  def init(opts) do
    port =
      Port.open(
        {:spawn_executable, Keyword.fetch!(opts, :executable)},
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: Keyword.get(opts, :args, []),
          cd: Keyword.fetch!(opts, :cwd),
          env: Keyword.get(opts, :env, [])
        ]
      )

    {:ok, %__MODULE__{port: port, terminal_id: Keyword.fetch!(opts, :terminal_id)}}
  end

  @impl true
  def handle_call(:output, _from, state) do
    {:reply, {:ok, state.output, state.exit_status}, state}
  end

  def handle_call(:wait_for_exit, from, %{exit_status: nil} = state) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:wait_for_exit, _from, state) do
    {:reply, {:ok, state.exit_status}, state}
  end

  def handle_call(:kill, _from, state) do
    close_port(state.port)
    {:reply, :ok, finish(state, -1)}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {:noreply, %{state | output: state.output <> data}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port, exit_status: nil} = state) do
    {:noreply, finish(state, status)}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port, exit_status: nil} = state) do
    {:noreply, finish(state, -1)}
  end

  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state), do: close_port(state.port)

  defp resolve_executable(command) when is_binary(command) do
    cond do
      Path.type(command) == :absolute and File.exists?(command) ->
        {:ok, command}

      executable = System.find_executable(command) ->
        {:ok, executable}

      true ->
        {:error, {:missing_executable, command}}
    end
  end

  defp resolve_executable(command), do: {:error, {:missing_executable, inspect(command)}}

  defp resolve_cwd(workspace, nil), do: {:ok, Path.expand(workspace)}

  defp resolve_cwd(workspace, cwd) when is_binary(cwd) do
    workspace = Path.expand(workspace)

    cwd =
      case Path.type(cwd) do
        :absolute -> Path.expand(cwd)
        _ -> Path.expand(cwd, workspace)
      end

    if cwd == workspace or String.starts_with?(cwd, workspace <> "/") do
      {:ok, cwd}
    else
      {:error, {:outside_workspace, cwd}}
    end
  end

  defp resolve_cwd(_workspace, cwd), do: {:error, {:invalid_cwd, inspect(cwd)}}

  defp env(env) do
    Enum.map(env, fn %ACP.EnvVariable{name: name, value: value} ->
      {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp finish(state, status) do
    Enum.each(state.waiters, &GenServer.reply(&1, {:ok, status}))
    %{state | exit_status: status, waiters: []}
  end

  defp close_port(port) do
    Port.close(port)
  catch
    :error, _ -> :ok
  end
end
