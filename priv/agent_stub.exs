defmodule StubAgent do
  alias Haven.ACPWire

  def run(workspace) do
    loop(%{
      workspace: workspace,
      next_permission_id: 1,
      awaiting_permission: %{},
      awaiting_file: %{},
      awaiting_terminal: %{},
      awaiting_prompt: %{}
    })
  end

  defp loop(state) do
    case IO.read(:line) do
      :eof ->
        :ok

      line ->
        line
        |> ACPWire.decode!()
        |> handle(state)
        |> loop()
    end
  end

  defp handle(%ACP.RPC.Request{method: "initialize", id: id, params: params}, state) do
    {:ok, _request} = ACP.InitializeRequest.from_json(params)

    result =
      ACP.ProtocolVersion.v1()
      |> ACP.InitializeResponse.new()
      |> ACP.InitializeResponse.to_json()

    ACPWire.send(ACP.RPC.Response.result(id, result))
    state
  end

  defp handle(%ACP.RPC.Request{method: "session/new", id: id, params: params}, state) do
    {:ok, _request} = ACP.NewSessionRequest.from_json(params)

    result =
      "stub-session-#{System.unique_integer([:positive])}"
      |> ACP.NewSessionResponse.new()
      |> ACP.NewSessionResponse.to_json()

    ACPWire.send(ACP.RPC.Response.result(id, result))
    state
  end

  defp handle(%ACP.RPC.Request{method: "session/prompt", id: prompt_id, params: params}, state) do
    {:ok, request} = ACP.PromptRequest.from_json(params)
    text = prompt_text(request.prompt)

    cond do
      text in ["permission", "permission-then-die"] ->
        permission_id = state.next_permission_id

        fields = %ACP.ToolCallUpdateFields{
          title: "Write file",
          status: :pending,
          raw_input: %{"path" => Path.join(state.workspace, "notes.md")}
        }

        permission =
          request.session_id
          |> ACP.RequestPermissionRequest.new(
            ACP.ToolCallUpdate.new("tool_#{permission_id}", fields),
            [
              ACP.PermissionOption.new("allow", "Allow once", :allow_once),
              ACP.PermissionOption.new("deny", "Deny", :reject_once)
            ]
          )

        ACPWire.send(
          ACP.RPC.Request.new(
            permission_id,
            "session/request_permission",
            ACP.RequestPermissionRequest.to_json(permission)
          )
        )

        if text == "permission-then-die" do
          System.halt(1)
        end

        %{
          state
          | next_permission_id: permission_id + 1,
            awaiting_permission:
              Map.put(state.awaiting_permission, permission_id, {prompt_id, request.session_id})
        }

      text == "wait" ->
        send_agent_text(request.session_id, "Waiting for cancellation.")

        %{
          state
          | awaiting_prompt:
              Map.update(state.awaiting_prompt, request.session_id, [prompt_id], &[prompt_id | &1])
        }

      text == "env" ->
        value = System.get_env("HAVEN_AGENT_ENV_SMOKE", "missing")
        send_agent_text(request.session_id, "Env: #{value}")
        send_prompt_result(prompt_id)
        state

      text == "unknown-update" ->
        fields = %ACP.ToolCallUpdateFields{
          title: "Inspect workspace",
          status: :in_progress,
          raw_input: %{"workspace" => state.workspace}
        }

        update =
          ACP.ToolCallUpdate.new("tool_unknown_1", fields)

        send_session_update(request.session_id, {:tool_call_update, update})
        send_prompt_result(prompt_id)
        state

      text == "read-file" ->
        request_id = state.next_permission_id
        session_id = request.session_id

        file_request =
          session_id
          |> ACP.ReadTextFileRequest.new("README.md")
          |> ACP.ReadTextFileRequest.to_json()

        ACPWire.send(ACP.RPC.Request.new(request_id, "fs/read_text_file", file_request))

        %{
          state
          | next_permission_id: request_id + 1,
            awaiting_file: Map.put(state.awaiting_file, request_id, {prompt_id, session_id, :read})
        }

      text == "write-file" ->
        request_id = state.next_permission_id
        session_id = request.session_id

        file_request =
          session_id
          |> ACP.WriteTextFileRequest.new("haven-written.txt", "written by Haven ACP\n")
          |> ACP.WriteTextFileRequest.to_json()

        ACPWire.send(ACP.RPC.Request.new(request_id, "fs/write_text_file", file_request))

        %{
          state
          | next_permission_id: request_id + 1,
            awaiting_file: Map.put(state.awaiting_file, request_id, {prompt_id, session_id, :write})
        }

      text == "terminal" ->
        session_id = request.session_id

        terminal_request =
          session_id
          |> ACP.CreateTerminalRequest.new("echo")
          |> Map.put(:args, ["hello"])
          |> ACP.CreateTerminalRequest.to_json()

        request_terminal(state, "terminal/create", terminal_request, %{
          prompt_id: prompt_id,
          session_id: session_id,
          step: :create
        })

      text == "kill-terminal" ->
        session_id = request.session_id

        terminal_request =
          session_id
          |> ACP.CreateTerminalRequest.new("sleep")
          |> Map.put(:args, ["30"])
          |> ACP.CreateTerminalRequest.to_json()

        request_terminal(state, "terminal/create", terminal_request, %{
          prompt_id: prompt_id,
          session_id: session_id,
          step: :kill_create
        })

      text == "malformed-after-start" ->
        IO.puts("this is not json")
        state

      text == "die" ->
        System.halt(1)

      true ->
        send_agent_text(request.session_id, "Echo: #{text}")
        send_prompt_result(prompt_id)
        state
    end
  end

  defp handle({:result, request_id, result}, state) do
    cond do
      Map.has_key?(state.awaiting_permission, request_id) ->
        handle_permission_result(request_id, result, state)

      Map.has_key?(state.awaiting_file, request_id) ->
        handle_file_result(request_id, result, state)

      Map.has_key?(state.awaiting_terminal, request_id) ->
        handle_terminal_result(request_id, {:ok, result}, state)

      true ->
        state
    end
  end

  defp handle({:error, request_id, error}, state) do
    cond do
      Map.has_key?(state.awaiting_file, request_id) ->
        handle_file_result(request_id, {:error, error}, state)

      Map.has_key?(state.awaiting_terminal, request_id) ->
        handle_terminal_result(request_id, {:error, error}, state)

      true ->
        state
    end
  end

  defp handle(%ACP.RPC.Notification{method: "session/cancel", params: params}, state) do
    {:ok, cancel} = ACP.CancelNotification.from_json(params)

    {prompt_ids, awaiting_prompt} = Map.pop(state.awaiting_prompt, cancel.session_id, [])

    Enum.each(prompt_ids, fn prompt_id ->
      send_agent_text(cancel.session_id, "Turn cancelled.")
      send_prompt_result(prompt_id)
    end)

    %{state | awaiting_prompt: awaiting_prompt}
  end

  defp handle(_message, state), do: state

  defp handle_permission_result(permission_id, result, state) do
    {:ok, response} = ACP.RequestPermissionResponse.from_json(result)

    case Map.pop(state.awaiting_permission, permission_id) do
      {nil, _} ->
        state

      {{prompt_id, session_id}, awaiting_permission} ->
        send_agent_text(session_id, permission_message(response.outcome))
        send_prompt_result(prompt_id)
        %{state | awaiting_permission: awaiting_permission}
    end
  end

  defp handle_file_result(request_id, {:error, error}, state) do
    case Map.pop(state.awaiting_file, request_id) do
      {nil, _} ->
        state

      {{prompt_id, session_id, _kind}, awaiting_file} ->
        send_agent_text(session_id, "File request failed: #{error.message}")
        send_prompt_result(prompt_id)
        %{state | awaiting_file: awaiting_file}
    end
  end

  defp handle_file_result(request_id, result, state) do
    case Map.pop(state.awaiting_file, request_id) do
      {nil, _} ->
        state

      {{prompt_id, session_id, :read}, awaiting_file} ->
        {:ok, response} = ACP.ReadTextFileResponse.from_json(result)
        first_line = response.content |> String.split("\n") |> List.first()
        send_agent_text(session_id, "Read file: #{first_line}")
        send_prompt_result(prompt_id)
        %{state | awaiting_file: awaiting_file}

      {{prompt_id, session_id, :write}, awaiting_file} ->
        {:ok, _response} = ACP.WriteTextFileResponse.from_json(result)
        send_agent_text(session_id, "Wrote file through Haven.")
        send_prompt_result(prompt_id)
        %{state | awaiting_file: awaiting_file}
    end
  end

  defp handle_terminal_result(request_id, {:error, error}, state) do
    case Map.pop(state.awaiting_terminal, request_id) do
      {nil, _} ->
        state

      {pending, awaiting_terminal} ->
        send_agent_text(pending.session_id, "Terminal failed: #{error.message}")
        send_prompt_result(pending.prompt_id)
        %{state | awaiting_terminal: awaiting_terminal}
    end
  end

  defp handle_terminal_result(request_id, {:ok, result}, state) do
    case Map.pop(state.awaiting_terminal, request_id) do
      {nil, _} ->
        state

      {%{step: :create} = pending, awaiting_terminal} ->
        {:ok, response} = ACP.CreateTerminalResponse.from_json(result)
        state = %{state | awaiting_terminal: awaiting_terminal}

        terminal_request =
          pending.session_id
          |> ACP.WaitForTerminalExitRequest.new(response.terminal_id)
          |> ACP.WaitForTerminalExitRequest.to_json()

        request_terminal(
          state,
          "terminal/wait_for_exit",
          terminal_request,
          Map.merge(pending, %{step: :wait, terminal_id: response.terminal_id})
        )

      {%{step: :kill_create} = pending, awaiting_terminal} ->
        {:ok, response} = ACP.CreateTerminalResponse.from_json(result)
        state = %{state | awaiting_terminal: awaiting_terminal}

        terminal_request =
          pending.session_id
          |> ACP.KillTerminalCommandRequest.new(response.terminal_id)
          |> ACP.KillTerminalCommandRequest.to_json()

        request_terminal(
          state,
          "terminal/kill",
          terminal_request,
          Map.merge(pending, %{step: :kill, terminal_id: response.terminal_id})
        )

      {%{step: :wait} = pending, awaiting_terminal} ->
        {:ok, response} = ACP.WaitForTerminalExitResponse.from_json(result)
        state = %{state | awaiting_terminal: awaiting_terminal}

        terminal_request =
          pending.session_id
          |> ACP.TerminalOutputRequest.new(pending.terminal_id)
          |> ACP.TerminalOutputRequest.to_json()

        request_terminal(
          state,
          "terminal/output",
          terminal_request,
          Map.merge(pending, %{step: :output, exit_code: response.exit_status.exit_code})
        )

      {%{step: :output} = pending, awaiting_terminal} ->
        {:ok, response} = ACP.TerminalOutputResponse.from_json(result)
        exit_code = terminal_exit_code(response.exit_status) || pending.exit_code
        output = String.trim(response.output)

        send_agent_text(pending.session_id, "Terminal output: #{output} (exit #{exit_code})")

        state = %{state | awaiting_terminal: awaiting_terminal}

        terminal_request =
          pending.session_id
          |> ACP.ReleaseTerminalRequest.new(pending.terminal_id)
          |> ACP.ReleaseTerminalRequest.to_json()

        request_terminal(state, "terminal/release", terminal_request, %{pending | step: :release})

      {%{step: :release} = pending, awaiting_terminal} ->
        {:ok, _response} = ACP.ReleaseTerminalResponse.from_json(result)
        send_prompt_result(pending.prompt_id)
        %{state | awaiting_terminal: awaiting_terminal}

      {%{step: :kill} = pending, awaiting_terminal} ->
        {:ok, _response} = ACP.KillTerminalCommandResponse.from_json(result)
        state = %{state | awaiting_terminal: awaiting_terminal}

        terminal_request =
          pending.session_id
          |> ACP.WaitForTerminalExitRequest.new(pending.terminal_id)
          |> ACP.WaitForTerminalExitRequest.to_json()

        request_terminal(state, "terminal/wait_for_exit", terminal_request, %{
          pending
          | step: :kill_wait
        })

      {%{step: :kill_wait} = pending, awaiting_terminal} ->
        {:ok, response} = ACP.WaitForTerminalExitResponse.from_json(result)
        state = %{state | awaiting_terminal: awaiting_terminal}

        terminal_request =
          pending.session_id
          |> ACP.TerminalOutputRequest.new(pending.terminal_id)
          |> ACP.TerminalOutputRequest.to_json()

        request_terminal(
          state,
          "terminal/output",
          terminal_request,
          Map.merge(pending, %{step: :kill_output, exit_code: response.exit_status.exit_code})
        )

      {%{step: :kill_output} = pending, awaiting_terminal} ->
        {:ok, response} = ACP.TerminalOutputResponse.from_json(result)
        exit_code = terminal_exit_code(response.exit_status) || pending.exit_code

        send_agent_text(pending.session_id, "Terminal killed (exit #{exit_code}).")

        state = %{state | awaiting_terminal: awaiting_terminal}

        terminal_request =
          pending.session_id
          |> ACP.ReleaseTerminalRequest.new(pending.terminal_id)
          |> ACP.ReleaseTerminalRequest.to_json()

        request_terminal(state, "terminal/release", terminal_request, %{
          pending
          | step: :kill_release
        })

      {%{step: :kill_release} = pending, awaiting_terminal} ->
        {:ok, _response} = ACP.ReleaseTerminalResponse.from_json(result)
        send_prompt_result(pending.prompt_id)
        %{state | awaiting_terminal: awaiting_terminal}
    end
  end

  defp prompt_text([{:text, %ACP.TextContent{text: text}} | _]), do: text
  defp prompt_text(_), do: ""

  defp permission_message({:selected, %ACP.SelectedPermissionOutcome{option_id: "allow"}}) do
    "Permission accepted. I would write notes.md now."
  end

  defp permission_message({:selected, %ACP.SelectedPermissionOutcome{option_id: "deny"}}) do
    "Permission denied. I will not write notes.md."
  end

  defp permission_message(:cancelled), do: "Permission cancelled."
  defp permission_message(_outcome), do: "Permission resolved."

  defp request_terminal(state, method, params, pending) do
    request_id = state.next_permission_id

    ACPWire.send(ACP.RPC.Request.new(request_id, method, params))

    %{
      state
      | next_permission_id: request_id + 1,
        awaiting_terminal: Map.put(state.awaiting_terminal, request_id, pending)
    }
  end

  defp terminal_exit_code(nil), do: nil
  defp terminal_exit_code(%ACP.TerminalExitStatus{exit_code: exit_code}), do: exit_code

  defp send_agent_text(session_id, text) do
    send_session_update(
      session_id,
      {:agent_message_chunk, ACP.ContentChunk.new(ACP.ContentBlock.from_string(text))}
    )
  end

  defp send_session_update(session_id, update) do
    notification =
      ACP.SessionNotification.new(session_id, update)

    ACPWire.send(
      ACP.RPC.Notification.new("session/update", ACP.SessionNotification.to_json(notification))
    )
  end

  defp send_prompt_result(prompt_id) do
    result =
      :end_turn
      |> ACP.PromptResponse.new()
      |> ACP.PromptResponse.to_json()

    ACPWire.send(ACP.RPC.Response.result(prompt_id, result))
  end
end

[workspace | _] = System.argv() ++ [File.cwd!()]
StubAgent.run(workspace)
