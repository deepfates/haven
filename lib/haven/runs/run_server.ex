defmodule Haven.Runs.RunServer do
  use GenServer

  alias Haven.Events
  alias Haven.PortIO
  alias Haven.Runs
  alias Haven.Runs.ACPClientHandler

  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    GenServer.start_link(__MODULE__, run_id, name: via(run_id))
  end

  def agent_permission_requested(server, request) do
    GenServer.call(server, {:agent_permission_requested, request}, :infinity)
  end

  defp via(run_id), do: {:via, Registry, {Haven.Runs.Registry, run_id}}

  @impl true
  def init(run_id) do
    Process.flag(:trap_exit, true)
    send(self(), :boot_agent)

    {:ok,
     %{
       run_id: run_id,
       port_io: nil,
       conn: nil,
       agent_session_id: nil,
       next_id: 1,
       next_permission_id: 1,
       pending_prompts: %{},
       pending_permissions: %{}
     }}
  end

  @impl true
  def handle_info(:boot_agent, state) do
    run = Runs.get_run!(state.run_id)

    {:ok, port_io} =
      PortIO.start_link(
        executable: System.find_executable("mix"),
        args: ["run", "--no-compile", "--no-start", "priv/agent_stub.exs", run.workspace]
      )

    {:ok, conn} =
      ACP.ClientSideConnection.start_link(
        input: port_io,
        output: port_io,
        handler: ACPClientHandler,
        handler_state: self()
      )

    ACP.ClientSideConnection.subscribe(conn)

    Events.append!(state.run_id, "agent_process_started", %{
      "command" => "priv/agent_stub.exs",
      "transport" => "mix run --no-compile --no-start"
    })

    Runs.update_status!(state.run_id, %{status: "initializing"})

    {:ok, initialize_result} =
      ACP.ClientSideConnection.initialize(
        conn,
        ACP.InitializeRequest.new(ACP.ProtocolVersion.v1())
      )

    {:ok, _response} = ACP.InitializeResponse.from_json(initialize_result)
    Events.append!(state.run_id, "agent_initialized", %{})

    {:ok, session_result} =
      ACP.ClientSideConnection.new_session(conn, ACP.NewSessionRequest.new(run.workspace))

    {:ok, session} = ACP.NewSessionResponse.from_json(session_result)

    Events.append!(state.run_id, "agent_session_started", %{
      "agent_session_id" => session.session_id
    })

    Runs.update_status!(state.run_id, %{status: "idle", agent_session_id: session.session_id})

    {:noreply, %{state | port_io: port_io, conn: conn, agent_session_id: session.session_id}}
  end

  def handle_info(
        {:acp_stream,
         {:incoming, :notification, "session/update", {:session_notification, notification}}},
        state
      ) do
    append_session_update(state.run_id, notification)
    {:noreply, state}
  end

  def handle_info({:acp_stream, _event}, state), do: {:noreply, state}

  def handle_info({:prompt_finished, id, {:ok, result}}, state) do
    if Map.has_key?(state.pending_prompts, id) do
      {:ok, _response} = ACP.PromptResponse.from_json(result)

      Events.append!(state.run_id, "turn_finished", %{"request_id" => id, "result" => result})
      Runs.update_status!(state.run_id, %{status: "idle"})
      {:noreply, %{state | pending_prompts: Map.delete(state.pending_prompts, id)}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:prompt_finished, id, {:error, error}}, state) do
    Events.append!(state.run_id, "turn_failed", %{
      "request_id" => id,
      "error" => inspect(error)
    })

    Runs.update_status!(state.run_id, %{status: "failed"})
    {:noreply, %{state | pending_prompts: Map.delete(state.pending_prompts, id)}}
  end

  def handle_info({:EXIT, pid, :normal}, %{conn: %ACP.ClientSideConnection{conn: pid}} = state) do
    status = if state.port_io, do: PortIO.exit_status(state.port_io), else: nil
    Events.append!(state.run_id, "agent_process_exited", %{"status" => status})

    Runs.update_status!(state.run_id, %{
      status: if(status in [nil, 0], do: "closed", else: "failed")
    })

    {:noreply, %{state | conn: nil}}
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    Events.append!(state.run_id, "agent_process_down", %{"reason" => inspect(reason)})
    Runs.update_status!(state.run_id, %{status: "failed"})
    {:noreply, %{state | conn: nil, port_io: nil}}
  end

  @impl true
  def handle_call({:send_prompt, text}, _from, state) do
    id = state.next_id

    Events.append!(state.run_id, "turn_started", %{"prompt" => text})
    Events.append!(state.run_id, "user_message", %{"text" => text})
    Runs.update_status!(state.run_id, %{status: "running"})

    prompt =
      state.agent_session_id
      |> ACP.PromptRequest.new([ACP.ContentBlock.from_string(text)])

    run_server = self()
    conn = state.conn

    spawn(fn ->
      result = ACP.ClientSideConnection.prompt(conn, prompt)
      send(run_server, {:prompt_finished, id, result})
    end)

    {:reply, :ok,
     %{state | next_id: id + 1, pending_prompts: Map.put(state.pending_prompts, id, text)}}
  end

  def handle_call({:resolve_permission, request_id, option_id}, _from, state) do
    request_id = normalize_id(request_id)

    with %{from: from} <- state.pending_permissions[request_id] do
      Events.append!(state.run_id, "permission_resolved", %{
        "request_id" => request_id,
        "option_id" => option_id,
        "outcome" => "selected"
      })

      response =
        {:selected, ACP.SelectedPermissionOutcome.new(option_id)}
        |> ACP.RequestPermissionResponse.new()

      GenServer.reply(from, {:ok, response})
      Runs.update_status!(state.run_id, %{status: "running"})

      {:reply, :ok,
       %{state | pending_permissions: Map.delete(state.pending_permissions, request_id)}}
    else
      _ ->
        Events.append!(state.run_id, "permission_resolution_ignored", %{
          "request_id" => request_id,
          "option_id" => option_id,
          "reason" => "not_pending"
        })

        {:reply, {:error, :not_pending}, state}
    end
  end

  def handle_call(:cancel, _from, state) do
    Events.append!(state.run_id, "turn_cancelled", %{})

    Enum.each(state.pending_permissions, fn {request_id, pending} ->
      Events.append!(state.run_id, "permission_resolved", %{
        "request_id" => request_id,
        "option_id" => "cancelled",
        "outcome" => "cancelled"
      })

      response =
        :cancelled
        |> ACP.RequestPermissionResponse.new()

      GenServer.reply(pending.from, {:ok, response})
    end)

    if state.agent_session_id do
      ACP.ClientSideConnection.cancel(
        state.conn,
        ACP.CancelNotification.new(state.agent_session_id)
      )
    end

    Runs.update_status!(state.run_id, %{status: "idle"})
    {:reply, :ok, %{state | pending_permissions: %{}, pending_prompts: %{}}}
  end

  def handle_call({:agent_permission_requested, request}, from, state) do
    request_id = state.next_permission_id

    payload =
      request
      |> ACP.RequestPermissionRequest.to_json()
      |> Map.put("request_id", request_id)

    Events.append!(state.run_id, "permission_requested", payload)
    Runs.update_status!(state.run_id, %{status: "waiting"})

    pending = %{request: request, from: from}

    {:noreply,
     %{
       state
       | next_permission_id: request_id + 1,
         pending_permissions: Map.put(state.pending_permissions, request_id, pending)
     }}
  end

  defp append_session_update(run_id, notification) do
    case notification.update do
      {:agent_message_chunk, %ACP.ContentChunk{content: {:text, %ACP.TextContent{text: text}}}} ->
        Events.append!(run_id, "agent_message_chunk", %{"text" => text})

      {type, _payload} ->
        Events.append!(
          run_id,
          Atom.to_string(type),
          ACP.SessionNotification.to_json(notification)["update"]
        )
    end
  end

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end
end
