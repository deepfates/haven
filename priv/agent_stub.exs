defmodule StubAgent do
  alias Haven.ACPWire

  def run(workspace) do
    loop(%{
      workspace: workspace,
      next_permission_id: 1,
      awaiting_permission: %{},
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
      text == "permission" ->
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

      text == "die" ->
        System.halt(1)

      true ->
        send_agent_text(request.session_id, "Echo: #{text}")
        send_prompt_result(prompt_id)
        state
    end
  end

  defp handle({:result, permission_id, result}, state) do
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
