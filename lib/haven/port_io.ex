defmodule Haven.PortIO do
  @moduledoc """
  Minimal IO device process for line-oriented stdio over an Erlang Port.

  `agent_client_protocol`'s connection layer reads and writes Elixir IO devices,
  while spawned agents are naturally represented as Ports. This process bridges
  those two shapes so ACP.Connection can own JSON-RPC correlation.
  """

  use GenServer

  defstruct [
    :port,
    :observer,
    buffer: "",
    lines: :queue.new(),
    readers: :queue.new(),
    exit_status: nil
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def exit_status(pid), do: GenServer.call(pid, :exit_status)
  def stop(pid), do: GenServer.stop(pid, :normal)

  @impl true
  def init(opts) do
    executable = Keyword.fetch!(opts, :executable)
    args = Keyword.get(opts, :args, [])
    env = Keyword.get(opts, :env, []) |> port_env()
    observer = Keyword.get(opts, :observer)

    port =
      Port.open(
        {:spawn_executable, executable},
        [:binary, :exit_status, :use_stdio, :stderr_to_stdout, args: args, env: env]
      )

    {:ok, %__MODULE__{port: port, observer: observer}}
  end

  @impl true
  def handle_call(:exit_status, _from, state), do: {:reply, state.exit_status, state}

  @impl true
  def handle_info({:io_request, from, reply_as, {:put_chars, _encoding, chars}}, state) do
    Port.command(state.port, IO.iodata_to_binary(chars))
    send(from, {:io_reply, reply_as, :ok})
    {:noreply, state}
  end

  def handle_info({:io_request, from, reply_as, {:get_line, _encoding, _prompt}}, state) do
    case :queue.out(state.lines) do
      {{:value, line}, lines} ->
        send(from, {:io_reply, reply_as, line})
        {:noreply, %{state | lines: lines}}

      {:empty, _lines} ->
        state =
          if state.exit_status do
            send(from, {:io_reply, reply_as, :eof})
            state
          else
            %{state | readers: :queue.in({from, reply_as}, state.readers)}
          end

        {:noreply, state}
    end
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state =
      data
      |> split_lines(state.buffer)
      |> deliver_lines(%{state | buffer: ""})

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = %{state | exit_status: status}
    state = flush_readers(state)
    {:noreply, state}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) do
    state = %{state | exit_status: state.exit_status || -1}
    state = flush_readers(state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state), do: close_port(state.port)

  defp close_port(port) do
    Port.close(port)
  catch
    :error, _ -> :ok
  end

  defp split_lines(data, buffer) do
    parts = String.split(buffer <> data, "\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {Enum.map(complete, &(&1 <> "\n")), rest}
  end

  defp deliver_lines({lines, rest}, state) do
    state = %{state | buffer: rest}
    Enum.reduce(lines, state, &deliver_line/2)
  end

  defp deliver_line(line, state) do
    notify_observer(state.observer, line)

    case :queue.out(state.readers) do
      {{:value, {from, reply_as}}, readers} ->
        send(from, {:io_reply, reply_as, line})
        %{state | readers: readers}

      {:empty, _readers} ->
        %{state | lines: :queue.in(line, state.lines)}
    end
  end

  defp flush_readers(state) do
    case :queue.out(state.readers) do
      {{:value, {from, reply_as}}, readers} ->
        send(from, {:io_reply, reply_as, :eof})
        flush_readers(%{state | readers: readers})

      {:empty, _readers} ->
        state
    end
  end

  defp notify_observer(nil, _line), do: :ok

  defp notify_observer(observer, line) when is_pid(observer) do
    send(observer, {:port_io_line, self(), line})
    :ok
  end

  defp port_env(env) do
    Enum.map(env, fn {name, value} ->
      {String.to_charlist(name), String.to_charlist(value)}
    end)
  end
end
