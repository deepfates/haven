defmodule Haven.FakeACPAgent do
  @moduledoc """
  Test-only ACP agent harness for protocol stress scenarios.

  The production stub remains a compact deterministic fixture. This module is
  compiled only in test and is launched through stdio by `priv/fake_agent.exs`
  so RunServer still exercises the configured external-agent path.
  """

  alias Haven.ACPWire

  def run(scenario, workspace) do
    loop(%{
      scenario: scenario,
      workspace: workspace,
      session_id: nil
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
  defp handle(_message, state), do: state

  defp handle_prompt("streaming", "partial-stream", prompt_id, session_id, state) do
    Enum.each(["Partial ", "streamed ", "answer."], fn text ->
      send_agent_text(session_id, text)
    end)

    send_prompt_result(prompt_id)
    state
  end

  defp handle_prompt(_scenario, text, prompt_id, session_id, state) do
    send_agent_text(session_id, "Fake echo: #{text}")
    send_prompt_result(prompt_id)
    state
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
