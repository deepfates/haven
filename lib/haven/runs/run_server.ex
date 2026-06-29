defmodule Haven.Runs.RunServer do
  use GenServer

  @file_write_preview_limit 4_000
  @file_write_diff_preview_limit 8_000

  alias Haven.Events
  alias Haven.PortIO
  alias Haven.Runs
  alias Haven.Runs.ACPClientHandler
  alias Haven.Terminals
  alias Haven.WorkspaceFiles
  alias Haven.Agents

  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    GenServer.start_link(__MODULE__, run_id, name: via(run_id))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :run_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def agent_permission_requested(server, request) do
    GenServer.call(server, {:agent_permission_requested, request}, :infinity)
  end

  def agent_read_text_file_requested(server, request) do
    GenServer.call(server, {:agent_read_text_file_requested, request}, :infinity)
  end

  def agent_write_text_file_requested(server, request) do
    GenServer.call(server, {:agent_write_text_file_requested, request}, :infinity)
  end

  def agent_terminal_requested(server, request) do
    GenServer.call(server, {:agent_terminal_requested, request}, :infinity)
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
       pending_permissions: %{},
       cancelled_session_ids: MapSet.new(),
       terminals: %{}
     }}
  end

  @impl true
  def handle_info(:boot_agent, state) do
    run = Runs.get_run!(state.run_id)

    with {:ok, command} <- Agents.command(run.agent, run.workspace),
         {:ok, port_io} <-
           PortIO.start_link(
             executable: command.executable,
             args: command.args,
             cd: command.cwd,
             env: command.env,
             observer: self()
           ) do
      boot_agent_connection(state, run, command, port_io)
    else
      {:error, reason} ->
        Events.append!(state.run_id, "agent_start_failed", %{"reason" => inspect(reason)})
        Runs.update_status!(state.run_id, %{status: "failed"})
        {:stop, :normal, state}
    end
  end

  def handle_info(
        {:acp_stream,
         {:incoming, :notification, "session/update", {:session_notification, notification}}},
        state
      ) do
    if suppress_session_update?(state, notification) do
      Events.append!(
        state.run_id,
        "agent_update_ignored",
        ignored_session_update_payload(notification, "turn_cancelled")
      )
    else
      append_session_update(state.run_id, notification)
    end

    {:noreply, state}
  end

  def handle_info({:acp_stream, _event}, state), do: {:noreply, state}

  def handle_info({:port_io_line, port_io, line}, %{port_io: port_io} = state) do
    cond do
      is_nil(state.agent_session_id) ->
        {:noreply, state}

      valid_json_rpc_line?(line) ->
        {:noreply, state}

      true ->
        reason = "malformed_agent_output"

        Events.append!(state.run_id, "agent_protocol_failed", %{
          "reason" => reason,
          "line" => String.trim_trailing(line)
        })

        state = fail_pending_work(state, reason)
        Runs.update_status!(state.run_id, %{status: "failed"})
        cleanup_agent(state)

        {:noreply, %{state | conn: nil, port_io: nil}}
    end
  end

  def handle_info({:port_io_line, _port_io, _line}, state), do: {:noreply, state}

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
    state = fail_prompt(state, id, inspect(error))
    Runs.update_status!(state.run_id, %{status: "failed"})
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, :normal}, %{conn: %ACP.ClientSideConnection{conn: pid}} = state) do
    status = if state.port_io, do: PortIO.exit_status(state.port_io), else: nil
    Events.append!(state.run_id, "agent_process_exited", %{"status" => status})

    {status, state} =
      if status in [nil, 0] and no_pending_work?(state) do
        {"closed", state}
      else
        {"failed", fail_pending_work(state, "agent_process_exited")}
      end

    Runs.update_status!(state.run_id, %{status: status})

    {:noreply, %{state | conn: nil}}
  end

  def handle_info({:EXIT, _pid, :normal}, %{conn: nil, port_io: nil} = state) do
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    Events.append!(state.run_id, "agent_process_down", %{"reason" => inspect(reason)})
    Runs.update_status!(state.run_id, %{status: "failed"})
    {:noreply, %{fail_pending_work(state, inspect(reason)) | conn: nil, port_io: nil}}
  end

  defp boot_agent_connection(state, run, command, port_io) do
    case ACP.ClientSideConnection.start_link(
           input: port_io,
           output: port_io,
           handler: ACPClientHandler,
           handler_state: self()
         ) do
      {:ok, conn} ->
        ACP.ClientSideConnection.subscribe(conn)

        Events.append!(state.run_id, "agent_process_started", %{
          "agent" => run.agent,
          "command" => command.label,
          "executable" => command.executable,
          "args" => command.args,
          "cwd" => command.cwd,
          "env" => Enum.map(command.env, fn {name, _value} -> name end)
        })

        Runs.update_status!(state.run_id, %{status: "initializing"})
        initialize_agent_connection(%{state | port_io: port_io, conn: conn}, run)

      {:error, reason} ->
        fail_agent_boot(%{state | port_io: port_io}, "agent_start_failed", reason)
    end
  end

  defp initialize_agent_connection(state, run) do
    with {:ok, initialize_result} <-
           safe_protocol_call(fn ->
             ACP.ClientSideConnection.initialize(
               state.conn,
               ACP.InitializeRequest.new(ACP.ProtocolVersion.v1())
             )
           end),
         {:ok, _response} <- ACP.InitializeResponse.from_json(initialize_result) do
      Events.append!(state.run_id, "agent_initialized", %{})

      with {:ok, session_result} <-
             safe_protocol_call(fn ->
               ACP.ClientSideConnection.new_session(
                 state.conn,
                 ACP.NewSessionRequest.new(run.workspace)
               )
             end),
           {:ok, session} <- ACP.NewSessionResponse.from_json(session_result) do
        Events.append!(state.run_id, "agent_session_started", %{
          "agent_session_id" => session.session_id
        })

        Runs.update_status!(state.run_id, %{status: "idle", agent_session_id: session.session_id})

        {:noreply, %{state | agent_session_id: session.session_id}}
      else
        {:error, reason} ->
          fail_agent_boot(state, "agent_protocol_failed", reason)
      end
    else
      {:error, reason} ->
        fail_agent_boot(state, "agent_protocol_failed", reason)
    end
  end

  defp safe_protocol_call(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:protocol_exit, reason}}
  end

  defp fail_agent_boot(state, event_type, reason) do
    Events.append!(state.run_id, event_type, %{"reason" => inspect(reason)})
    Runs.update_status!(state.run_id, %{status: "failed"})
    cleanup_agent(state)
    {:stop, :normal, state}
  end

  @impl true
  def handle_call({:send_prompt, text}, _from, state) do
    run = Runs.get_run!(state.run_id)

    if can_start_prompt?(run, state) do
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
       %{
         state
         | next_id: id + 1,
           pending_prompts: Map.put(state.pending_prompts, id, text),
           cancelled_session_ids:
             MapSet.delete(state.cancelled_session_ids, state.agent_session_id)
       }}
    else
      {:reply, {:error, :busy}, state}
    end
  end

  def handle_call({:resolve_permission, request_id, option_id}, _from, state) do
    request_id = normalize_id(request_id)

    with %{kind: _kind} = pending <- state.pending_permissions[request_id] do
      Events.append!(state.run_id, "permission_resolved", %{
        "request_id" => request_id,
        "option_id" => option_id,
        "outcome" => "selected",
        "actor" => "local_user"
      })

      state = apply_permission_resolution(state, pending, option_id)
      Runs.update_status!(state.run_id, %{status: "running"})

      {:reply, :ok,
       %{state | pending_permissions: Map.delete(state.pending_permissions, request_id)}}
    else
      _ ->
        Events.append!(state.run_id, "permission_resolution_ignored", %{
          "request_id" => request_id,
          "option_id" => option_id,
          "reason" => "not_pending",
          "actor" => "local_user"
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
        "outcome" => "cancelled",
        "actor" => "local_user"
      })

      cancel_pending_permission(pending)
    end)

    if state.agent_session_id do
      ACP.ClientSideConnection.cancel(
        state.conn,
        ACP.CancelNotification.new(state.agent_session_id)
      )
    end

    Runs.update_status!(state.run_id, %{status: "idle"})

    {:reply, :ok,
     %{
       state
       | pending_permissions: %{},
         pending_prompts: %{},
         cancelled_session_ids: MapSet.put(state.cancelled_session_ids, state.agent_session_id)
     }}
  end

  def handle_call({:agent_permission_requested, request}, from, state) do
    request_id = state.next_permission_id

    payload =
      request
      |> ACP.RequestPermissionRequest.to_json()
      |> Map.put("request_id", request_id)

    if Runs.get_run!(state.run_id).status == "failed" do
      Events.append!(state.run_id, "permission_requested", payload)
      append_system_permission_cancelled(state.run_id, request_id, "agent_process_exited")
      cancel_pending_permission(%{kind: :agent_permission, from: from})

      {:noreply, %{state | next_permission_id: request_id + 1}}
    else
      Events.append!(state.run_id, "permission_requested", payload)
      Runs.update_status!(state.run_id, %{status: "waiting"})

      pending = %{kind: :agent_permission, request: request, from: from}

      {:noreply,
       %{
         state
         | next_permission_id: request_id + 1,
           pending_permissions: Map.put(state.pending_permissions, request_id, pending)
       }}
    end
  end

  def handle_call({:agent_read_text_file_requested, request}, from, state) do
    run = Runs.get_run!(state.run_id)
    payload = file_request_payload(request)
    request_id = state.next_permission_id

    Events.append!(state.run_id, "file_read_requested", payload)

    pending = file_read_pending(from, request, payload, run.workspace)

    case file_capability_decision(run, "file_read") do
      "allow" ->
        Events.append!(state.run_id, "capability_policy_applied", %{
          "capability" => "file_read",
          "decision" => "allow",
          "request_id" => request_id
        })

        resolve_pending_permission(state, pending, "allow")
        {:noreply, %{state | next_permission_id: request_id + 1}}

      "deny" ->
        Events.append!(state.run_id, "capability_policy_applied", %{
          "capability" => "file_read",
          "decision" => "deny",
          "request_id" => request_id
        })

        resolve_pending_permission(state, pending, "deny")
        {:noreply, %{state | next_permission_id: request_id + 1}}

      _ask ->
        Events.append!(
          state.run_id,
          "permission_requested",
          file_permission_payload(:read, request_id, payload)
        )

        Runs.update_status!(state.run_id, %{status: "waiting"})

        {:noreply,
         %{
           state
           | next_permission_id: request_id + 1,
             pending_permissions: Map.put(state.pending_permissions, request_id, pending)
         }}
    end
  end

  def handle_call({:agent_write_text_file_requested, request}, from, state) do
    run = Runs.get_run!(state.run_id)
    payload = file_request_payload(request)
    request_id = state.next_permission_id

    Events.append!(
      state.run_id,
      "file_write_requested",
      Map.put(payload, "bytes", byte_size(request.content))
    )

    pending = file_write_pending(from, request, payload, run.workspace)

    case file_capability_decision(run, "file_write") do
      "allow" ->
        Events.append!(state.run_id, "capability_policy_applied", %{
          "capability" => "file_write",
          "decision" => "allow",
          "request_id" => request_id
        })

        resolve_pending_permission(state, pending, "allow")
        {:noreply, %{state | next_permission_id: request_id + 1}}

      "deny" ->
        Events.append!(state.run_id, "capability_policy_applied", %{
          "capability" => "file_write",
          "decision" => "deny",
          "request_id" => request_id
        })

        resolve_pending_permission(state, pending, "deny")
        {:noreply, %{state | next_permission_id: request_id + 1}}

      _ask ->
        Events.append!(
          state.run_id,
          "permission_requested",
          file_permission_payload(
            :write,
            request_id,
            file_write_permission_input(payload, request.content, run.workspace, request)
          )
        )

        Runs.update_status!(state.run_id, %{status: "waiting"})

        {:noreply,
         %{
           state
           | next_permission_id: request_id + 1,
             pending_permissions: Map.put(state.pending_permissions, request_id, pending)
         }}
    end
  end

  def handle_call(
        {:agent_terminal_requested, {:create_terminal, request} = agent_request},
        from,
        state
      ) do
    run = Runs.get_run!(state.run_id)
    payload = terminal_request_payload(agent_request)
    request_id = state.next_permission_id

    Events.append!(state.run_id, "terminal_create_requested", payload)

    pending = terminal_create_pending(from, request, payload, run.workspace)

    case capability_decision(run, "terminal_create") do
      "deny" ->
        Events.append!(state.run_id, "capability_policy_applied", %{
          "capability" => "terminal_create",
          "decision" => "deny"
        })

        resolve_pending_permission(state, pending, "deny")
        {:noreply, %{state | next_permission_id: request_id + 1}}

      "ask" ->
        Events.append!(
          state.run_id,
          "permission_requested",
          terminal_permission_payload(request_id, payload)
        )

        Runs.update_status!(state.run_id, %{status: "waiting"})

        {:noreply,
         %{
           state
           | next_permission_id: request_id + 1,
             pending_permissions: Map.put(state.pending_permissions, request_id, pending)
         }}

      _allow ->
        Events.append!(
          state.run_id,
          "capability_policy_applied",
          %{"capability" => "terminal_create", "decision" => "allow"}
        )

        state = resolve_pending_permission(state, pending, "allow")
        {:noreply, %{state | next_permission_id: request_id + 1}}
    end
  end

  def handle_call(
        {:agent_terminal_requested, {:terminal_output, request} = agent_request},
        _from,
        state
      ) do
    payload = terminal_request_payload(agent_request)
    Events.append!(state.run_id, "terminal_output_requested", payload)

    with {:ok, pid} <- fetch_terminal(state, request.terminal_id),
         {:ok, output, exit_status} <- Terminals.output(pid) do
      Events.append!(
        state.run_id,
        "terminal_output_succeeded",
        Map.merge(payload, %{"bytes" => byte_size(output), "exit_status" => exit_status})
      )

      response = %ACP.TerminalOutputResponse{
        output: output,
        exit_status: terminal_exit_status(exit_status)
      }

      {:reply, {:ok, response}, state}
    else
      {:error, error} ->
        Events.append!(
          state.run_id,
          "terminal_output_failed",
          Map.merge(payload, %{"error" => ACP.Error.to_json(error)})
        )

        {:reply, {:error, error}, state}
    end
  end

  def handle_call(
        {:agent_terminal_requested, {:wait_for_terminal_exit, request} = agent_request},
        _from,
        state
      ) do
    payload = terminal_request_payload(agent_request)
    Events.append!(state.run_id, "terminal_wait_requested", payload)

    with {:ok, pid} <- fetch_terminal(state, request.terminal_id),
         {:ok, exit_status} <- Terminals.wait_for_exit(pid) do
      Events.append!(
        state.run_id,
        "terminal_wait_succeeded",
        Map.merge(payload, %{"exit_status" => exit_status})
      )

      {:reply,
       {:ok, ACP.WaitForTerminalExitResponse.new(ACP.TerminalExitStatus.new(exit_status))}, state}
    else
      {:error, error} ->
        Events.append!(
          state.run_id,
          "terminal_wait_failed",
          Map.merge(payload, %{"error" => ACP.Error.to_json(error)})
        )

        {:reply, {:error, error}, state}
    end
  end

  def handle_call(
        {:agent_terminal_requested, {:kill_terminal_command, request} = agent_request},
        _from,
        state
      ) do
    payload = terminal_request_payload(agent_request)
    Events.append!(state.run_id, "terminal_kill_requested", payload)

    with {:ok, pid} <- fetch_terminal(state, request.terminal_id),
         :ok <- Terminals.kill(pid) do
      Events.append!(state.run_id, "terminal_kill_succeeded", payload)
      {:reply, {:ok, ACP.KillTerminalCommandResponse.new()}, state}
    else
      {:error, error} ->
        Events.append!(
          state.run_id,
          "terminal_kill_failed",
          Map.merge(payload, %{"error" => ACP.Error.to_json(error)})
        )

        {:reply, {:error, error}, state}
    end
  end

  def handle_call(
        {:agent_terminal_requested, {:release_terminal, request} = agent_request},
        _from,
        state
      ) do
    payload = terminal_request_payload(agent_request)
    Events.append!(state.run_id, "terminal_release_requested", payload)

    case Map.pop(state.terminals, request.terminal_id) do
      {nil, _terminals} ->
        error = ACP.Error.resource_not_found(request.terminal_id)

        Events.append!(
          state.run_id,
          "terminal_release_failed",
          Map.merge(payload, %{"error" => ACP.Error.to_json(error)})
        )

        {:reply, {:error, error}, state}

      {pid, terminals} ->
        Terminals.release(pid)
        Events.append!(state.run_id, "terminal_released", payload)
        {:reply, {:ok, ACP.ReleaseTerminalResponse.new()}, %{state | terminals: terminals}}
    end
  end

  def handle_call(:shutdown, _from, state) do
    cleanup_agent(state)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def terminate(_reason, state), do: cleanup_agent(state)

  defp cleanup_agent(state) do
    Enum.each(state.terminals, fn {_terminal_id, pid} ->
      stop_if_alive(pid, &Terminals.release/1)
    end)

    stop_if_alive(state.port_io, &PortIO.stop/1)

    case state.conn do
      %ACP.ClientSideConnection{} = conn ->
        stop_if_alive(conn.conn, fn _pid -> ACP.ClientSideConnection.stop(conn) end)

      _ ->
        :ok
    end
  end

  defp stop_if_alive(nil, _stop), do: :ok

  defp stop_if_alive(pid, stop) when is_pid(pid) do
    if Process.alive?(pid) do
      stop.(pid)
    end
  catch
    :exit, _ -> :ok
  end

  defp file_request_payload(%ACP.ReadTextFileRequest{} = request) do
    %{
      "session_id" => request.session_id,
      "path" => request.path,
      "line" => request.line,
      "limit" => request.limit
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp file_request_payload(%ACP.WriteTextFileRequest{} = request) do
    %{
      "session_id" => request.session_id,
      "path" => request.path
    }
  end

  defp file_write_permission_input(payload, content, workspace, request) do
    preview = String.slice(content, 0, @file_write_preview_limit)

    diff_preview =
      WorkspaceFiles.write_text_file_diff_preview(
        workspace,
        request,
        @file_write_diff_preview_limit
      )

    payload
    |> Map.put("bytes", byte_size(content))
    |> Map.put("content_preview", preview)
    |> Map.put("content_truncated", String.length(content) > @file_write_preview_limit)
    |> Map.put("content_preview_limit", @file_write_preview_limit)
    |> Map.merge(diff_preview)
  end

  defp file_permission_payload(kind, request_id, raw_input) do
    {title, allow_name} =
      case kind do
        :read -> {"Read file", "Allow read"}
        :write -> {"Write file", "Allow write"}
      end

    %{
      "request_id" => request_id,
      "toolCall" => %{
        "toolCallId" => "file_#{kind}_#{request_id}",
        "title" => title,
        "status" => "pending",
        "rawInput" => raw_input
      },
      "options" => [
        %{"optionId" => "allow", "name" => allow_name, "kind" => "allow_once"},
        %{"optionId" => "deny", "name" => "Deny", "kind" => "reject_once"}
      ]
    }
  end

  defp file_read_pending(from, request, payload, workspace) do
    %{
      kind: :file_read,
      from: from,
      request: request,
      payload: payload,
      workspace: workspace
    }
  end

  defp file_write_pending(from, request, payload, workspace) do
    %{
      kind: :file_write,
      from: from,
      request: request,
      payload: payload,
      workspace: workspace
    }
  end

  defp terminal_permission_payload(request_id, raw_input) do
    %{
      "request_id" => request_id,
      "toolCall" => %{
        "toolCallId" => "terminal_create_#{request_id}",
        "title" => "Create terminal",
        "status" => "pending",
        "rawInput" => raw_input
      },
      "options" => [
        %{"optionId" => "allow", "name" => "Allow terminal", "kind" => "allow_once"},
        %{"optionId" => "deny", "name" => "Deny", "kind" => "reject_once"}
      ]
    }
  end

  defp terminal_create_pending(from, request, payload, workspace) do
    %{
      kind: :terminal_create,
      from: from,
      request: request,
      payload: payload,
      workspace: workspace
    }
  end

  defp file_capability_decision(run, capability), do: capability_decision(run, capability)

  defp capability_decision(run, capability) do
    run.capability_policy
    |> Haven.Runs.Run.capability_policy()
    |> Map.fetch!(capability)
  end

  defp apply_permission_resolution(state, pending, option_id) do
    case resolve_pending_permission(state, pending, option_id) do
      %{run_id: _run_id} = state -> state
      _result -> state
    end
  end

  defp resolve_pending_permission(_state, %{kind: :agent_permission, from: from}, option_id) do
    response =
      {:selected, ACP.SelectedPermissionOutcome.new(option_id)}
      |> ACP.RequestPermissionResponse.new()

    GenServer.reply(from, {:ok, response})
  end

  defp resolve_pending_permission(state, %{kind: :file_read} = pending, "allow") do
    case WorkspaceFiles.read_text_file(pending.workspace, pending.request) do
      {:ok, content, path} ->
        Events.append!(
          state.run_id,
          "file_read_succeeded",
          Map.put(pending.payload, "resolved_path", path)
        )

        GenServer.reply(pending.from, {:ok, ACP.ReadTextFileResponse.new(content)})

      {:error, error} ->
        Events.append!(
          state.run_id,
          "file_read_failed",
          Map.merge(pending.payload, %{"error" => ACP.Error.to_json(error)})
        )

        GenServer.reply(pending.from, {:error, error})
    end
  end

  defp resolve_pending_permission(state, %{kind: :file_read} = pending, _option_id) do
    error = permission_denied_error(pending.payload["path"])

    Events.append!(
      state.run_id,
      "file_read_denied",
      Map.merge(pending.payload, %{"error" => ACP.Error.to_json(error)})
    )

    GenServer.reply(pending.from, {:error, error})
  end

  defp resolve_pending_permission(state, %{kind: :file_write} = pending, "allow") do
    case WorkspaceFiles.write_text_file(pending.workspace, pending.request) do
      {:ok, path} ->
        Events.append!(
          state.run_id,
          "file_write_succeeded",
          Map.put(pending.payload, "resolved_path", path)
        )

        GenServer.reply(pending.from, {:ok, ACP.WriteTextFileResponse.new()})

      {:error, error} ->
        Events.append!(
          state.run_id,
          "file_write_failed",
          Map.merge(pending.payload, %{"error" => ACP.Error.to_json(error)})
        )

        GenServer.reply(pending.from, {:error, error})
    end
  end

  defp resolve_pending_permission(state, %{kind: :file_write} = pending, _option_id) do
    error = permission_denied_error(pending.payload["path"])

    Events.append!(
      state.run_id,
      "file_write_denied",
      Map.merge(pending.payload, %{"error" => ACP.Error.to_json(error)})
    )

    GenServer.reply(pending.from, {:error, error})
  end

  defp resolve_pending_permission(state, %{kind: :terminal_create} = pending, "allow") do
    with {:ok, opts} <- Terminals.command_options(pending.workspace, pending.request),
         {:ok, pid} <- Terminals.start(opts) do
      terminal_id = Keyword.fetch!(opts, :terminal_id)

      Events.append!(
        state.run_id,
        "terminal_created",
        Map.merge(pending.payload, %{"terminal_id" => terminal_id})
      )

      GenServer.reply(pending.from, {:ok, ACP.CreateTerminalResponse.new(terminal_id)})
      %{state | terminals: Map.put(state.terminals, terminal_id, pid)}
    else
      {:error, reason} ->
        error = terminal_error("Could not create terminal", reason)

        Events.append!(
          state.run_id,
          "terminal_create_failed",
          Map.merge(pending.payload, %{"error" => ACP.Error.to_json(error)})
        )

        GenServer.reply(pending.from, {:error, error})
        state
    end
  end

  defp resolve_pending_permission(state, %{kind: :terminal_create} = pending, _option_id) do
    error = terminal_permission_denied_error()

    Events.append!(
      state.run_id,
      "terminal_create_denied",
      Map.merge(pending.payload, %{"error" => ACP.Error.to_json(error)})
    )

    GenServer.reply(pending.from, {:error, error})
    state
  end

  defp cancel_pending_permission(%{kind: :agent_permission, from: from}) do
    response =
      :cancelled
      |> ACP.RequestPermissionResponse.new()

    GenServer.reply(from, {:ok, response})
  end

  defp cancel_pending_permission(%{kind: :file_read} = pending) do
    GenServer.reply(pending.from, {:error, permission_denied_error(pending.payload["path"])})
  end

  defp cancel_pending_permission(%{kind: :file_write} = pending) do
    GenServer.reply(pending.from, {:error, permission_denied_error(pending.payload["path"])})
  end

  defp cancel_pending_permission(%{kind: :terminal_create} = pending) do
    GenServer.reply(pending.from, {:error, terminal_permission_denied_error()})
  end

  defp permission_denied_error(path) do
    ACP.Error.new(-32003, "Permission denied")
    |> ACP.Error.with_data(%{"path" => path, "reason" => "permission_denied"})
  end

  defp terminal_permission_denied_error do
    ACP.Error.new(-32003, "Permission denied")
    |> ACP.Error.with_data(%{"target" => "terminal/create", "reason" => "permission_denied"})
  end

  defp terminal_request_payload({_type, request}) do
    request
    |> Map.from_struct()
    |> Map.drop([:meta])
    |> stringify_keys()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp fetch_terminal(state, terminal_id) do
    case Map.fetch(state.terminals, terminal_id) do
      {:ok, pid} -> {:ok, pid}
      :error -> {:error, ACP.Error.resource_not_found(terminal_id)}
    end
  end

  defp terminal_exit_status(nil), do: nil
  defp terminal_exit_status(status), do: ACP.TerminalExitStatus.new(status)

  defp terminal_error(message, reason) do
    %{ACP.Error.internal_error() | message: message}
    |> ACP.Error.with_data(%{"reason" => inspect(reason)})
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

  defp suppress_session_update?(state, notification) do
    MapSet.member?(state.cancelled_session_ids, notification.session_id) and
      no_pending_work?(state)
  end

  defp ignored_session_update_payload(notification, reason) do
    %{
      "session_id" => notification.session_id,
      "reason" => reason,
      "update_type" => session_update_type(notification.update)
    }
  end

  defp session_update_type({type, _payload}), do: Atom.to_string(type)
  defp session_update_type(_update), do: "unknown"

  defp normalize_id(id) when is_integer(id), do: id

  defp normalize_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> id
    end
  end

  defp no_pending_work?(state) do
    state.pending_prompts == %{} and state.pending_permissions == %{}
  end

  defp can_start_prompt?(run, state) do
    run.status == "idle" and not is_nil(state.conn) and not is_nil(state.agent_session_id) and
      no_pending_work?(state)
  end

  defp valid_json_rpc_line?(line) do
    case Jason.decode(line) do
      {:ok, %{} = message} ->
        json_rpc_message?(message)

      _ ->
        false
    end
  end

  defp json_rpc_message?(%{"id" => _id, "method" => method}) when is_binary(method), do: true
  defp json_rpc_message?(%{"id" => _id, "result" => _result}), do: true
  defp json_rpc_message?(%{"id" => _id, "error" => _error}), do: true
  defp json_rpc_message?(%{"method" => method}) when is_binary(method), do: true
  defp json_rpc_message?(_message), do: false

  defp fail_pending_work(state, reason) do
    state =
      Enum.reduce(Map.keys(state.pending_prompts), state, fn id, acc ->
        fail_prompt(acc, id, reason)
      end)

    Enum.each(state.pending_permissions, fn {request_id, pending} ->
      append_system_permission_cancelled(state.run_id, request_id, reason)
      cancel_pending_permission(pending)
    end)

    %{state | pending_permissions: %{}}
  end

  defp fail_prompt(state, id, reason) do
    if Map.has_key?(state.pending_prompts, id) do
      Events.append!(state.run_id, "turn_failed", %{
        "request_id" => id,
        "error" => reason
      })
    end

    %{state | pending_prompts: Map.delete(state.pending_prompts, id)}
  end

  defp append_system_permission_cancelled(run_id, request_id, reason) do
    Events.append!(run_id, "permission_resolved", %{
      "request_id" => request_id,
      "option_id" => "cancelled",
      "outcome" => "cancelled",
      "reason" => reason,
      "actor" => "system"
    })
  end
end
