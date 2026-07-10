defmodule Haven.Runs.RunServer do
  use GenServer

  @file_write_preview_limit 4_000
  @file_write_diff_preview_limit 8_000

  alias Haven.Events
  alias Haven.FileChanges
  alias Haven.PermissionAudits
  alias Haven.PortIO
  alias Haven.Runs
  alias Haven.Runs.ACPClientHandler
  alias Haven.ACPClientSide
  alias Haven.TerminalSessions
  alias Haven.Terminals
  alias Haven.WorkspaceFiles
  alias Haven.Agents

  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    GenServer.start_link(__MODULE__, opts, name: via(run_id))
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
  def init(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
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
       agent_thought_redacted?: false,
       load_session_supported?: false,
       session_modes: nil,
       retry_prompt: Keyword.get(opts, :retry_prompt),
       continue_prompt: Keyword.get(opts, :continue_prompt),
       replay: nil,
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
        Events.append!(
          state.run_id,
          "agent_start_failed",
          runtime_failure_payload(run, reason)
        )

        Runs.update_status!(state.run_id, %{status: "failed"})
        {:stop, :normal, state}
    end
  end

  def handle_info(
        {:acp_stream,
         {:incoming, :notification, "session/update", {:session_notification, notification}}},
        state
      ) do
    state =
      if suppress_session_update?(state, notification) do
        Events.append!(
          state.run_id,
          "agent_update_ignored",
          ignored_session_update_payload(notification, "turn_cancelled")
        )

        state
      else
        append_session_update(state, notification)
      end

    {:noreply, state}
  end

  def handle_info(
        {:acp_stream,
         {:incoming, :notification, "session/update",
          {:ext_notification, %ACP.ExtNotification{params: params}}}},
        state
      ) do
    {:noreply,
     append_session_event(state, "agent_update_unknown", raw_session_update_payload(params))}
  end

  def handle_info({:acp_stream, _event}, state), do: {:noreply, state}

  def handle_info({:port_io_line, port_io, line}, %{port_io: port_io} = state) do
    cond do
      is_nil(state.agent_session_id) ->
        {:noreply, state}

      valid_json_rpc_line?(line) ->
        {:noreply, state}

      idle_agent_output?(state) ->
        Events.append!(state.run_id, "agent_output_ignored", %{
          "reason" => "non_protocol_idle_output",
          "line" => String.trim_trailing(line)
        })

        {:noreply, state}

      true ->
        reason = "malformed_agent_output"
        run = Runs.get_run!(state.run_id)

        Events.append!(state.run_id, "agent_protocol_failed", %{
          "reason" => reason,
          "agent" => run.agent,
          "workspace" => run.workspace,
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

  # End of the session/load replay window. The marker was self-sent right
  # after the load response, so every replayed session/update notification
  # (queued in the mailbox while the load call blocked) has been processed by
  # the time it arrives. Report the fold tally loudly, then dispatch any
  # deferred recovery prompt so replayed history lands in the ledger BEFORE
  # the new turn starts.
  def handle_info(
        {:session_replay_settled, session_id},
        %{replay: %{session_id: session_id} = replay} = state
      ) do
    Events.append!(state.run_id, "session_replay_settled", %{
      "agent_session_id" => session_id,
      "folded" => replay.folded,
      "folded_total" => replay.folded |> Map.values() |> Enum.sum(),
      "replayed_new" => replay.new_count
    })

    state = %{state | replay: nil}

    state =
      cond do
        state.conn ->
          maybe_start_recovery_prompt(state)

        is_binary(state.retry_prompt) or is_binary(state.continue_prompt) ->
          Events.append!(state.run_id, "recovery_prompt_abandoned", %{
            "reason" => "agent_disconnected_during_replay"
          })

          %{state | retry_prompt: nil, continue_prompt: nil}

        true ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:session_replay_settled, _session_id}, state), do: {:noreply, state}

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
    Events.append!(
      state.run_id,
      "agent_process_down",
      runtime_failure_payload(Runs.get_run!(state.run_id), reason)
    )

    Runs.update_status!(state.run_id, %{status: "failed"})
    {:noreply, %{fail_pending_work(state, inspect(reason)) | conn: nil, port_io: nil}}
  end

  defp boot_agent_connection(state, run, command, port_io) do
    case start_client_connection(port_io) do
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
        fail_agent_boot(%{state | port_io: port_io}, run, "agent_start_failed", reason)
    end
  end

  defp start_client_connection(port_io) do
    opts = [
      input: port_io,
      output: port_io,
      handler: ACPClientHandler,
      handler_state: self(),
      side: ACPClientSide
    ]

    case ACP.Connection.start_link(opts) do
      {:ok, conn} -> {:ok, %ACP.ClientSideConnection{conn: conn}}
      error -> error
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
         {:ok, initialize_response} <- ACP.InitializeResponse.from_json(initialize_result) do
      load_session_supported? = load_session_supported?(initialize_response)

      Events.append!(state.run_id, "agent_initialized", %{
        "load_session_supported" => load_session_supported?
      })

      state = %{state | load_session_supported?: load_session_supported?}

      with {:ok, state} <- maybe_authenticate_agent(state, initialize_result) do
        start_agent_session(state, run)
      else
        {:error, reason} ->
          fail_agent_boot(state, run, "agent_protocol_failed", reason)
      end
    else
      {:error, reason} ->
        fail_agent_boot(state, run, "agent_protocol_failed", reason)
    end
  end

  defp maybe_authenticate_agent(state, initialize_result) do
    case auth_method_id(initialize_result) do
      nil ->
        {:ok, state}

      method_id ->
        with {:ok, authenticate_result} <-
               safe_protocol_call(fn ->
                 ACP.ClientSideConnection.authenticate(
                   state.conn,
                   ACP.AuthenticateRequest.new(method_id)
                 )
               end),
             {:ok, _response} <- ACP.AuthenticateResponse.from_json(authenticate_result) do
          Events.append!(state.run_id, "agent_authenticated", %{"method_id" => method_id})
          {:ok, state}
        end
    end
  end

  defp auth_method_id(%{"authMethods" => [%{"id" => method_id} | _rest]})
       when is_binary(method_id) and method_id != "",
       do: method_id

  defp auth_method_id(_initialize_result), do: nil

  defp load_session_supported?(%ACP.InitializeResponse{agent_capabilities: capabilities}) do
    match?(%ACP.AgentCapabilities{load_session: true}, capabilities)
  end

  # Session start order: when the run carries a prior agent session id, resume
  # it via session/load — but only when the agent advertised the loadSession
  # capability in its initialize response (ACP gates session/load on it).
  # Every skipped or failed resume is recorded loudly as an event before
  # falling back to a fresh session/new.
  defp start_agent_session(state, run) do
    case maybe_load_agent_session(state, run) do
      {:resumed, state} -> {:noreply, state}
      {:start_new, state} -> start_new_agent_session(state, run)
    end
  end

  defp maybe_load_agent_session(state, %{agent_session_id: session_id} = run)
       when is_binary(session_id) and session_id != "" do
    if state.load_session_supported? do
      load_agent_session(state, run, session_id)
    else
      Events.append!(state.run_id, "session_load_skipped", %{
        "agent_session_id" => session_id,
        "reason" => "load_session_capability_not_advertised"
      })

      {:start_new, state}
    end
  end

  defp maybe_load_agent_session(state, _run), do: {:start_new, state}

  defp load_agent_session(state, run, session_id) do
    request = %{
      ACP.LoadSessionRequest.new(session_id, run.workspace)
      | mcp_servers: mcp_servers(run.workspace)
    }

    with {:ok, load_result} <-
           safe_protocol_call(fn ->
             ACP.ClientSideConnection.load_session(state.conn, request)
           end),
         {:ok, response} <- ACP.LoadSessionResponse.from_json(load_result) do
      Events.append!(
        state.run_id,
        "agent_session_loaded",
        maybe_put_modes(%{"agent_session_id" => session_id}, response.modes)
      )

      Runs.update_status!(state.run_id, %{status: "idle", agent_session_id: session_id})

      state =
        state
        |> Map.put(:agent_session_id, session_id)
        |> Map.put(:session_modes, response.modes)
        |> begin_session_replay(session_id)

      {:resumed, state}
    else
      {:error, reason} ->
        Events.append!(state.run_id, "session_load_failed", %{
          "agent_session_id" => session_id,
          "error" => inspect(reason),
          "fallback" => "session_new"
        })

        {:start_new, state}
    end
  end

  defp start_new_agent_session(state, run) do
    with {:ok, session_result} <-
           safe_protocol_call(fn ->
             ACP.ClientSideConnection.new_session(
               state.conn,
               new_session_request(run)
             )
           end),
         {:ok, session} <- ACP.NewSessionResponse.from_json(session_result) do
      Events.append!(
        state.run_id,
        "agent_session_started",
        maybe_put_modes(%{"agent_session_id" => session.session_id}, session.modes)
      )

      Runs.update_status!(state.run_id, %{status: "idle", agent_session_id: session.session_id})

      state =
        state
        |> Map.put(:agent_session_id, session.session_id)
        |> Map.put(:session_modes, session.modes)
        |> maybe_start_recovery_prompt()

      {:noreply, state}
    else
      {:error, reason} ->
        fail_agent_boot(state, run, "agent_protocol_failed", reason)
    end
  end

  defp maybe_put_modes(payload, nil), do: payload

  defp maybe_put_modes(payload, %ACP.SessionModeState{} = modes) do
    Map.put(payload, "modes", ACP.SessionModeState.to_json(modes))
  end

  defp new_session_request(run) do
    %{
      ACP.NewSessionRequest.new(run.workspace)
      | mcp_servers: mcp_servers(run.workspace)
    }
  end

  defp mcp_servers(workspace) do
    :haven
    |> Application.get_env(:mcp_servers, [])
    |> Enum.flat_map(&mcp_server(&1, workspace))
  end

  defp mcp_server(%{"name" => _name} = server, workspace) do
    server = substitute_workspace(server, workspace)

    case ACP.McpServer.from_json(server) do
      {:ok, server} -> [server]
      _error -> []
    end
  end

  defp mcp_server(%{name: name, command: command} = server, workspace) do
    server
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put("name", name)
    |> Map.put("command", command)
    |> mcp_server(workspace)
  end

  defp mcp_server(_server, _workspace), do: []

  defp substitute_workspace(value, workspace) when is_binary(value) do
    String.replace(value, "{workspace}", workspace)
  end

  defp substitute_workspace(values, workspace) when is_list(values) do
    Enum.map(values, &substitute_workspace(&1, workspace))
  end

  defp substitute_workspace(value, workspace) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {key, substitute_workspace(nested_value, workspace)}
    end)
  end

  defp substitute_workspace(value, _workspace), do: value

  defp safe_protocol_call(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:protocol_exit, reason}}
  end

  defp maybe_start_recovery_prompt(%{retry_prompt: prompt} = state) when is_binary(prompt) do
    Events.append!(state.run_id, "turn_retry_requested", %{"prompt" => prompt})

    state
    |> Map.put(:retry_prompt, nil)
    |> start_prompt(prompt)
  end

  defp maybe_start_recovery_prompt(%{continue_prompt: prompt} = state) when is_binary(prompt) do
    Events.append!(state.run_id, "turn_continue_requested", %{"prompt" => prompt})

    state
    |> Map.put(:continue_prompt, nil)
    |> start_prompt(prompt)
  end

  defp maybe_start_recovery_prompt(state), do: state

  defp start_prompt(state, text) do
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

    %{
      state
      | next_id: id + 1,
        pending_prompts: Map.put(state.pending_prompts, id, text),
        agent_thought_redacted?: false,
        cancelled_session_ids: MapSet.delete(state.cancelled_session_ids, state.agent_session_id)
    }
  end

  defp fail_agent_boot(state, run, event_type, reason) do
    Events.append!(state.run_id, event_type, runtime_failure_payload(run, reason))
    Runs.update_status!(state.run_id, %{status: "failed"})
    cleanup_agent(state)
    {:stop, :normal, state}
  end

  defp runtime_failure_payload(run, reason) do
    %{
      "reason" => inspect(reason),
      "agent" => run.agent,
      "workspace" => run.workspace
    }
  end

  defp idle_agent_output?(state) do
    state.pending_prompts == %{} and state.pending_permissions == %{}
  end

  defp known_session_mode?(%ACP.SessionModeState{available_modes: modes}, mode_id) do
    Enum.any?(modes, &(&1.id == mode_id))
  end

  defp set_session_mode(state, mode_id) do
    request = ACP.SetSessionModeRequest.new(state.agent_session_id, mode_id)

    with {:ok, result} <-
           safe_protocol_call(fn ->
             ACP.ClientSideConnection.set_session_mode(state.conn, request)
           end),
         {:ok, _response} <- ACP.SetSessionModeResponse.from_json(result) do
      Events.append!(state.run_id, "session_mode_changed", %{
        "agent_session_id" => state.agent_session_id,
        "mode_id" => mode_id
      })

      modes = %{state.session_modes | current_mode_id: mode_id}
      {:reply, :ok, %{state | session_modes: modes}}
    else
      {:error, reason} ->
        Events.append!(state.run_id, "session_mode_failed", %{
          "mode_id" => mode_id,
          "error" => inspect(reason)
        })

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:send_prompt, text}, _from, state) do
    run = Runs.get_run!(state.run_id)

    if can_start_prompt?(run, state) do
      {:reply, :ok, start_prompt(state, text)}
    else
      {:reply, {:error, :busy}, state}
    end
  end

  # Permission-mode switch via session/set_mode. ACP advertises available
  # modes per session (NewSessionResponse/LoadSessionResponse `modes`), so the
  # call is gated on that advertisement: an agent that never advertised modes
  # gets a loud recorded rejection instead of a silent no-op.
  def handle_call({:set_session_mode, mode_id}, _from, state) do
    cond do
      is_nil(state.conn) or is_nil(state.agent_session_id) ->
        Events.append!(state.run_id, "session_mode_rejected", %{
          "mode_id" => mode_id,
          "reason" => "no_active_session"
        })

        {:reply, {:error, :no_active_session}, state}

      is_nil(state.session_modes) ->
        Events.append!(state.run_id, "session_mode_rejected", %{
          "mode_id" => mode_id,
          "reason" => "modes_not_advertised"
        })

        {:reply, {:error, :modes_not_advertised}, state}

      not known_session_mode?(state.session_modes, mode_id) ->
        Events.append!(state.run_id, "session_mode_rejected", %{
          "mode_id" => mode_id,
          "reason" => "unknown_mode",
          "available_mode_ids" => Enum.map(state.session_modes.available_modes, & &1.id)
        })

        {:reply, {:error, :unknown_mode}, state}

      true ->
        set_session_mode(state, mode_id)
    end
  end

  def handle_call({:resolve_permission, request_id, option_id}, _from, state) do
    request_id = normalize_id(request_id)

    with %{kind: _kind} = pending <- state.pending_permissions[request_id] do
      payload = %{
        "request_id" => request_id,
        "option_id" => option_id,
        "outcome" => "selected",
        "actor" => "local_user"
      }

      Events.append!(state.run_id, "permission_resolved", payload)
      PermissionAudits.mark_resolved!(state.run_id, request_id, payload)

      state = apply_permission_resolution(state, pending, option_id)
      Runs.update_status!(state.run_id, %{status: "running"})

      {:reply, :ok,
       %{state | pending_permissions: Map.delete(state.pending_permissions, request_id)}}
    else
      _ ->
        payload = %{
          "request_id" => request_id,
          "option_id" => option_id,
          "reason" => "not_pending",
          "actor" => "local_user"
        }

        Events.append!(state.run_id, "permission_resolution_ignored", payload)
        PermissionAudits.record_ignored_resolution!(state.run_id, request_id, payload)

        {:reply, {:error, :not_pending}, state}
    end
  end

  def handle_call(:cancel, _from, state) do
    Events.append!(state.run_id, "turn_cancelled", %{})

    Enum.each(state.pending_permissions, fn {request_id, pending} ->
      payload = %{
        "request_id" => request_id,
        "option_id" => "cancelled",
        "outcome" => "cancelled",
        "actor" => "local_user"
      }

      Events.append!(state.run_id, "permission_resolved", payload)
      PermissionAudits.mark_resolved!(state.run_id, request_id, payload)

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
      append_permission_requested!(state, :agent_permission, payload)
      append_system_permission_cancelled(state.run_id, request_id, "agent_process_exited")
      cancel_pending_permission(%{kind: :agent_permission, from: from})

      {:noreply, %{state | next_permission_id: request_id + 1}}
    else
      append_permission_requested!(state, :agent_permission, payload)
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
    path_scopes = file_capability_path_scopes(run, "file_read")

    cond do
      not WorkspaceFiles.path_in_scopes?(run.workspace, request.path, path_scopes) ->
        Events.append!(state.run_id, "capability_policy_applied", %{
          "capability" => "file_read",
          "decision" => "deny",
          "reason" => "path_scope",
          "request_id" => request_id,
          "path_scopes" => path_scopes || []
        })

        deny_pending_file_scope(state, pending)
        {:noreply, %{state | next_permission_id: request_id + 1}}

      file_capability_decision(run, "file_read") == "allow" ->
        Events.append!(state.run_id, "capability_policy_applied", %{
          "capability" => "file_read",
          "decision" => "allow",
          "request_id" => request_id
        })

        resolve_pending_permission(state, pending, "allow")
        {:noreply, %{state | next_permission_id: request_id + 1}}

      file_capability_decision(run, "file_read") == "deny" ->
        Events.append!(state.run_id, "capability_policy_applied", %{
          "capability" => "file_read",
          "decision" => "deny",
          "request_id" => request_id
        })

        resolve_pending_permission(state, pending, "deny")
        {:noreply, %{state | next_permission_id: request_id + 1}}

      true ->
        append_permission_requested!(
          state,
          :file_read,
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
    request_id = state.next_permission_id
    change_id = "file-write-#{System.unique_integer([:positive])}"
    payload = request |> file_request_payload() |> Map.put("change_id", change_id)
    write_input = file_write_permission_input(payload, request.content, run.workspace, request)

    Events.append!(
      state.run_id,
      "file_write_requested",
      Map.put(payload, "bytes", byte_size(request.content))
    )

    FileChanges.create_pending!(
      state.run_id,
      file_write_projection_attrs(write_input, request.content)
    )

    pending = file_write_pending(state.run_id, from, request, payload, run.workspace)
    path_scopes = file_capability_path_scopes(run, "file_write")

    cond do
      not WorkspaceFiles.path_in_scopes?(run.workspace, request.path, path_scopes) ->
        Events.append!(state.run_id, "capability_policy_applied", %{
          "capability" => "file_write",
          "decision" => "deny",
          "reason" => "path_scope",
          "request_id" => request_id,
          "path_scopes" => path_scopes || []
        })

        deny_pending_file_scope(state, pending)
        {:noreply, %{state | next_permission_id: request_id + 1}}

      file_capability_decision(run, "file_write") == "allow" ->
        Events.append!(state.run_id, "capability_policy_applied", %{
          "capability" => "file_write",
          "decision" => "allow",
          "request_id" => request_id
        })

        resolve_pending_permission(state, pending, "allow")
        {:noreply, %{state | next_permission_id: request_id + 1}}

      file_capability_decision(run, "file_write") == "deny" ->
        Events.append!(state.run_id, "capability_policy_applied", %{
          "capability" => "file_write",
          "decision" => "deny",
          "request_id" => request_id
        })

        resolve_pending_permission(state, pending, "deny")
        {:noreply, %{state | next_permission_id: request_id + 1}}

      true ->
        append_permission_requested!(
          state,
          :file_write,
          file_permission_payload(
            :write,
            request_id,
            write_input
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
        append_permission_requested!(
          state,
          :terminal_create,
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
      TerminalSessions.record_output!(state.run_id, request.terminal_id, output, exit_status)

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
      TerminalSessions.mark_exited!(state.run_id, request.terminal_id, exit_status)

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
      TerminalSessions.mark_killed!(state.run_id, request.terminal_id)
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
        TerminalSessions.mark_released!(state.run_id, request.terminal_id)
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

  defp file_write_projection_attrs(write_input, content) do
    %{
      change_id: write_input["change_id"],
      path: write_input["path"],
      status: "pending",
      diff_kind: write_input["diff_kind"] || "unknown",
      bytes: byte_size(content),
      existing_bytes: write_input["existing_bytes"],
      content_preview: write_input["content_preview"] || "",
      content_preview_limit: write_input["content_preview_limit"] || @file_write_preview_limit,
      content_truncated: write_input["content_truncated"] || false,
      diff_preview: write_input["diff_preview"] || "",
      diff_preview_limit: write_input["diff_preview_limit"] || @file_write_diff_preview_limit,
      diff_truncated: write_input["diff_truncated"] || false
    }
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

  defp file_write_pending(run_id, from, request, payload, workspace) do
    %{
      kind: :file_write,
      run_id: run_id,
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

  defp terminal_session_attrs(request, opts, terminal_info) do
    %{
      terminal_id: terminal_info.terminal_id,
      command: request.command,
      args: %{"items" => request.args || []},
      cwd: Keyword.fetch!(opts, :cwd),
      executable: Keyword.get(opts, :executable),
      env_keys: %{"items" => terminal_env_keys(request.env || [])},
      os_pid: terminal_info.os_pid,
      status: "running",
      output_bytes: terminal_info.output_bytes || 0
    }
  end

  defp terminal_env_keys(env) do
    env
    |> Enum.map(fn
      %ACP.EnvVariable{name: name} -> name
      %{"name" => name} -> name
      %{name: name} -> name
      _other -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp file_capability_decision(run, capability), do: capability_decision(run, capability)

  defp file_capability_path_scopes(run, capability) do
    run.capability_policy
    |> Haven.Runs.Run.capability_policy()
    |> Map.get("#{capability}_paths")
  end

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
        FileChanges.mark_applied!(state.run_id, pending.payload["change_id"], path)

        Events.append!(
          state.run_id,
          "file_write_succeeded",
          Map.put(pending.payload, "resolved_path", path)
        )

        GenServer.reply(pending.from, {:ok, ACP.WriteTextFileResponse.new()})

      {:error, error} ->
        FileChanges.mark_failed!(
          state.run_id,
          pending.payload["change_id"],
          ACP.Error.to_json(error)
        )

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
    FileChanges.mark_denied!(state.run_id, pending.payload["change_id"], ACP.Error.to_json(error))

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
      terminal_info = Terminals.info(pid)

      Events.append!(
        state.run_id,
        "terminal_created",
        Map.merge(pending.payload, %{"terminal_id" => terminal_id})
      )

      TerminalSessions.create_session!(
        state.run_id,
        terminal_session_attrs(pending.request, opts, terminal_info)
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

  defp deny_pending_file_scope(state, %{kind: kind} = pending)
       when kind in [:file_read, :file_write] do
    error = path_scope_denied_error(pending.payload["path"])
    event_type = if kind == :file_read, do: "file_read_denied", else: "file_write_denied"

    if kind == :file_write do
      FileChanges.mark_denied!(
        state.run_id,
        pending.payload["change_id"],
        ACP.Error.to_json(error)
      )
    end

    Events.append!(
      state.run_id,
      event_type,
      Map.merge(pending.payload, %{"error" => ACP.Error.to_json(error)})
    )

    GenServer.reply(pending.from, {:error, error})
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
    error = permission_denied_error(pending.payload["path"])

    FileChanges.mark_cancelled!(
      pending.run_id,
      pending.payload["change_id"],
      ACP.Error.to_json(error)
    )

    GenServer.reply(pending.from, {:error, error})
  end

  defp cancel_pending_permission(%{kind: :terminal_create} = pending) do
    GenServer.reply(pending.from, {:error, terminal_permission_denied_error()})
  end

  defp permission_denied_error(path) do
    ACP.Error.new(-32003, "Permission denied")
    |> ACP.Error.with_data(%{"path" => path, "reason" => "permission_denied"})
  end

  defp path_scope_denied_error(path) do
    ACP.Error.new(-32003, "Permission denied")
    |> ACP.Error.with_data(%{"path" => path, "reason" => "path_scope_denied"})
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

  defp append_session_update(state, notification) do
    case notification.update do
      {:agent_message_chunk, %ACP.ContentChunk{content: {:text, %ACP.TextContent{text: text}}}} ->
        append_session_event(state, "agent_message_chunk", %{"text" => text})

      {:agent_thought_chunk, %ACP.ContentChunk{content: {:text, %ACP.TextContent{text: text}}}} ->
        append_redacted_agent_thought(state, %{
          "content_type" => "text",
          "first_chunk_length" => String.length(text)
        })

      {:agent_thought_chunk, _payload} ->
        append_redacted_agent_thought(state, %{})

      {:current_mode_update, %ACP.CurrentModeUpdate{current_mode_id: mode_id}} ->
        state =
          append_session_event(
            state,
            "current_mode_update",
            ACP.SessionNotification.to_json(notification)["update"]
          )

        case state.session_modes do
          %ACP.SessionModeState{} = modes ->
            %{state | session_modes: %{modes | current_mode_id: mode_id}}

          _no_modes ->
            state
        end

      {type, _payload} ->
        append_session_event(
          state,
          Atom.to_string(type),
          ACP.SessionNotification.to_json(notification)["update"]
        )
    end
  end

  # Replayed-history dedupe (dee-ndfx). session/load replays prior turns as
  # session/update notifications, but the ledger already holds the original
  # live events, so a resumed run would show its history twice. Between the
  # load response and the :session_replay_settled marker every incoming
  # session update is checked against a multiset of already-recorded events
  # keyed by stable CONTENT identity {type, normalized payload} (the agent
  # provides no per-event ids; this is exact content matching, never
  # positional guessing). Byte-identical duplicates are folded — not
  # re-appended — and every fold is tallied in one loud
  # session_replay_settled event, so nothing disappears invisibly and the
  # folded content already exists verbatim in the ledger. Genuinely new
  # replayed events (content the ledger never recorded, e.g. turns that
  # happened while Haven was detached, or agents that re-chunk their replay)
  # are appended with a "replay" => true payload marker so their provenance
  # stays visible.
  defp begin_session_replay(state, session_id) do
    seen =
      state.run_id
      |> Events.list_for_run()
      |> Enum.reduce(%{}, fn event, acc ->
        Map.update(acc, event_identity(event.type, event.payload), 1, &(&1 + 1))
      end)

    send(self(), {:session_replay_settled, session_id})

    %{state | replay: %{session_id: session_id, seen: seen, folded: %{}, new_count: 0}}
  end

  defp append_session_event(%{replay: %{} = replay} = state, type, payload) do
    case pop_seen_identity(replay.seen, replay_fold_identities(type, payload)) do
      {:folded, seen} ->
        folded = Map.update(replay.folded, type, 1, &(&1 + 1))
        %{state | replay: %{replay | seen: seen, folded: folded}}

      :new ->
        Events.append!(state.run_id, type, Map.put(payload, "replay", true))
        %{state | replay: %{replay | new_count: replay.new_count + 1}}
    end
  end

  defp append_session_event(state, type, payload) do
    Events.append!(state.run_id, type, payload)
    state
  end

  # Haven records the prompt it sends as a "user_message" event; agents
  # replay that same content back as a "user_message_chunk" update. Same
  # content, two spellings — fold the replayed chunk against either.
  defp replay_fold_identities("user_message_chunk" = type, payload) do
    case payload do
      %{"content" => %{"text" => text}} when is_binary(text) ->
        [event_identity(type, payload), event_identity("user_message", %{"text" => text})]

      _payload ->
        [event_identity(type, payload)]
    end
  end

  defp replay_fold_identities(type, payload), do: [event_identity(type, payload)]

  # The "replay" marker is provenance, not content: strip it so events that
  # landed as marked replays in an earlier resume still fold on later resumes.
  defp event_identity(type, payload) do
    {type, payload |> Events.normalize_payload() |> Map.delete("replay")}
  end

  defp pop_seen_identity(_seen, []), do: :new

  defp pop_seen_identity(seen, [identity | rest]) do
    case seen do
      %{^identity => count} when count > 0 ->
        {:folded, Map.put(seen, identity, count - 1)}

      _no_remaining_match ->
        pop_seen_identity(seen, rest)
    end
  end

  defp append_redacted_agent_thought(%{agent_thought_redacted?: true} = state, _payload),
    do: state

  defp append_redacted_agent_thought(state, payload) do
    state =
      append_session_event(
        state,
        "agent_thought_redacted",
        Map.merge(%{"redacted" => true}, payload)
      )

    %{state | agent_thought_redacted?: true}
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

  defp raw_session_update_payload(params) do
    update = Map.get(params, "update", %{})

    %{
      "session_id" => Map.get(params, "sessionId"),
      "update_type" => Map.get(update, "sessionUpdate", "unknown"),
      "update" => update
    }
  end

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

  defp append_permission_requested!(state, kind, payload) do
    Events.append!(state.run_id, "permission_requested", payload)
    PermissionAudits.create_pending!(state.run_id, kind, payload)
  end

  defp append_system_permission_cancelled(run_id, request_id, reason) do
    payload = %{
      "request_id" => request_id,
      "option_id" => "cancelled",
      "outcome" => "cancelled",
      "reason" => reason,
      "actor" => "system"
    }

    Events.append!(run_id, "permission_resolved", payload)
    PermissionAudits.mark_resolved!(run_id, request_id, payload)
  end
end
