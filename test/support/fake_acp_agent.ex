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
      awaiting_permissions: %{}
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
    if Map.has_key?(state.awaiting_permissions, request_id) do
      handle_permission_result(request_id, result, state)
    else
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
end
