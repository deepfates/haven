defmodule Haven.FakeACPAgent do
  @moduledoc """
  Test-only ACP agent harness for protocol stress scenarios.

  The production stub remains a compact deterministic fixture. This module is
  compiled only in test and is launched through stdio by
  `test/support/fake_agent_runner.exs` so RunServer still exercises the
  configured external-agent path.
  """

  alias Haven.ACPWire

  def run(scenario, workspace) do
    loop(%{
      scenario: scenario,
      workspace: workspace,
      session_id: nil,
      next_request_id: 1,
      awaiting_permissions: %{},
      awaiting_file: %{},
      awaiting_terminal: %{}
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
    session_id = "fake-session-#{System.unique_integer([:positive])}"

    result =
      session_id
      |> ACP.NewSessionResponse.new()
      |> ACP.NewSessionResponse.to_json()

    ACPWire.send(ACP.RPC.Response.result(id, result))
    %{state | session_id: session_id}
  end

  defp handle(%ACP.RPC.Request{method: "session/prompt", id: id, params: params}, state) do
    {:ok, request} = ACP.PromptRequest.from_json(params)

    state.scenario
    |> handle_prompt(prompt_text(request.prompt), id, request.session_id, state)
  end

  defp handle(%ACP.RPC.Notification{method: "session/cancel"}, state), do: state

  defp handle({:result, request_id, result}, state) do
    cond do
      Map.has_key?(state.awaiting_permissions, request_id) ->
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

  defp handle(_message, state), do: state

  defp handle_prompt("streaming", "partial-stream", prompt_id, session_id, state) do
    Enum.each(["Partial ", "streamed ", "answer."], fn text ->
      send_agent_text(session_id, text)
    end)

    send_prompt_result(prompt_id)
    state
  end

  defp handle_prompt("duplicate-permission", "duplicate-permission", prompt_id, session_id, state) do
    state
    |> request_permission(prompt_id, session_id, "First permission", "tool_duplicate_1")
    |> request_permission(prompt_id, session_id, "Second permission", "tool_duplicate_2")
  end

  defp handle_prompt("malformed", "malformed-after-start", _prompt_id, _session_id, state) do
    IO.puts("fake malformed frame")
    state
  end

  defp handle_prompt("file-read", "read-file", prompt_id, session_id, state) do
    request_id = state.next_request_id

    request =
      session_id
      |> ACP.ReadTextFileRequest.new("README.md")
      |> ACP.ReadTextFileRequest.to_json()

    ACPWire.send(ACP.RPC.Request.new(request_id, "fs/read_text_file", request))

    %{
      state
      | next_request_id: request_id + 1,
        awaiting_file: Map.put(state.awaiting_file, request_id, {prompt_id, session_id, :read})
    }
  end

  defp handle_prompt("terminal", "terminal", prompt_id, session_id, state) do
    request =
      session_id
      |> ACP.CreateTerminalRequest.new("echo")
      |> Map.put(:args, ["external"])
      |> ACP.CreateTerminalRequest.to_json()

    request_terminal(state, "terminal/create", request, %{
      prompt_id: prompt_id,
      session_id: session_id,
      step: :create
    })
  end

  defp handle_prompt("crash", "die", _prompt_id, _session_id, _state) do
    System.halt(1)
  end

  defp handle_prompt(_scenario, text, prompt_id, session_id, state) do
    send_agent_text(session_id, "Fake echo: #{text}")
    send_prompt_result(prompt_id)
    state
  end

  defp request_permission(state, prompt_id, session_id, title, tool_call_id) do
    request_id = state.next_request_id

    fields = %ACP.ToolCallUpdateFields{
      title: title,
      status: :pending,
      raw_input: %{"workspace" => state.workspace, "toolCallId" => tool_call_id}
    }

    permission =
      session_id
      |> ACP.RequestPermissionRequest.new(
        ACP.ToolCallUpdate.new(tool_call_id, fields),
        [
          ACP.PermissionOption.new("allow", "Allow once", :allow_once),
          ACP.PermissionOption.new("deny", "Deny", :reject_once)
        ]
      )

    ACPWire.send(
      ACP.RPC.Request.new(
        request_id,
        "session/request_permission",
        ACP.RequestPermissionRequest.to_json(permission)
      )
    )

    %{
      state
      | next_request_id: request_id + 1,
        awaiting_permissions:
          Map.put(state.awaiting_permissions, request_id, {prompt_id, session_id})
    }
  end

  defp handle_permission_result(request_id, result, state) do
    {:ok, _response} = ACP.RequestPermissionResponse.from_json(result)

    case Map.pop(state.awaiting_permissions, request_id) do
      {nil, _awaiting_permissions} ->
        state

      {{prompt_id, session_id}, awaiting_permissions} ->
        state = %{state | awaiting_permissions: awaiting_permissions}

        if awaiting_permissions == %{} do
          send_agent_text(session_id, "Duplicate permissions resolved.")
          send_prompt_result(prompt_id)
        end

        state
    end
  end

  defp handle_file_result(request_id, {:error, error}, state) do
    case Map.pop(state.awaiting_file, request_id) do
      {nil, _awaiting_file} ->
        state

      {{prompt_id, session_id, _kind}, awaiting_file} ->
        send_agent_text(session_id, "File request failed: #{error.message}")
        send_prompt_result(prompt_id)
        %{state | awaiting_file: awaiting_file}
    end
  end

  defp handle_file_result(request_id, result, state) do
    case Map.pop(state.awaiting_file, request_id) do
      {nil, _awaiting_file} ->
        state

      {{prompt_id, session_id, :read}, awaiting_file} ->
        {:ok, response} = ACP.ReadTextFileResponse.from_json(result)
        first_line = response.content |> String.split("\n") |> List.first()
        send_agent_text(session_id, "Fake read file: #{first_line}")
        send_prompt_result(prompt_id)
        %{state | awaiting_file: awaiting_file}
    end
  end

  defp handle_terminal_result(request_id, {:error, error}, state) do
    case Map.pop(state.awaiting_terminal, request_id) do
      {nil, _awaiting_terminal} ->
        state

      {pending, awaiting_terminal} ->
        send_agent_text(pending.session_id, "Fake terminal failed: #{error.message}")
        send_prompt_result(pending.prompt_id)
        %{state | awaiting_terminal: awaiting_terminal}
    end
  end

  defp handle_terminal_result(request_id, {:ok, result}, state) do
    case Map.pop(state.awaiting_terminal, request_id) do
      {nil, _awaiting_terminal} ->
        state

      {%{step: :create} = pending, awaiting_terminal} ->
        {:ok, response} = ACP.CreateTerminalResponse.from_json(result)
        state = %{state | awaiting_terminal: awaiting_terminal}

        request =
          pending.session_id
          |> ACP.WaitForTerminalExitRequest.new(response.terminal_id)
          |> ACP.WaitForTerminalExitRequest.to_json()

        request_terminal(
          state,
          "terminal/wait_for_exit",
          request,
          Map.merge(pending, %{step: :wait, terminal_id: response.terminal_id})
        )

      {%{step: :wait} = pending, awaiting_terminal} ->
        {:ok, response} = ACP.WaitForTerminalExitResponse.from_json(result)
        state = %{state | awaiting_terminal: awaiting_terminal}

        request =
          pending.session_id
          |> ACP.TerminalOutputRequest.new(pending.terminal_id)
          |> ACP.TerminalOutputRequest.to_json()

        request_terminal(
          state,
          "terminal/output",
          request,
          Map.merge(pending, %{step: :output, exit_code: terminal_exit_code(response.exit_status)})
        )

      {%{step: :output} = pending, awaiting_terminal} ->
        {:ok, response} = ACP.TerminalOutputResponse.from_json(result)
        exit_code = terminal_exit_code(response.exit_status) || pending.exit_code
        output = String.trim(response.output)

        send_agent_text(pending.session_id, "Fake terminal output: #{output} (exit #{exit_code})")

        state = %{state | awaiting_terminal: awaiting_terminal}

        request =
          pending.session_id
          |> ACP.ReleaseTerminalRequest.new(pending.terminal_id)
          |> ACP.ReleaseTerminalRequest.to_json()

        request_terminal(state, "terminal/release", request, %{pending | step: :release})

      {%{step: :release} = pending, awaiting_terminal} ->
        {:ok, _response} = ACP.ReleaseTerminalResponse.from_json(result)
        send_prompt_result(pending.prompt_id)
        %{state | awaiting_terminal: awaiting_terminal}
    end
  end

  defp prompt_text([{:text, %ACP.TextContent{text: text}} | _]), do: text
  defp prompt_text(_prompt), do: ""

  defp send_agent_text(session_id, text) do
    update =
      {:agent_message_chunk, ACP.ContentChunk.new(ACP.ContentBlock.from_string(text))}

    notification = ACP.SessionNotification.new(session_id, update)

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

  defp request_terminal(state, method, params, pending) do
    request_id = state.next_request_id

    ACPWire.send(ACP.RPC.Request.new(request_id, method, params))

    %{
      state
      | next_request_id: request_id + 1,
        awaiting_terminal: Map.put(state.awaiting_terminal, request_id, pending)
    }
  end

  defp terminal_exit_code(nil), do: nil
  defp terminal_exit_code(%ACP.TerminalExitStatus{exit_code: exit_code}), do: exit_code
end
