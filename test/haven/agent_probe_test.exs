defmodule Haven.AgentProbeTest do
  use Haven.DataCase

  alias Haven.AgentProbe

  test "runs a prompt through Haven's configured agent path" do
    assert {:ok, report} =
             AgentProbe.run(
               agent: "stub-acp",
               workspace: File.cwd!(),
               prompt: "hello from probe",
               timeout: 5_000
             )

    assert report.agent == "stub-acp"
    assert report.workspace == File.cwd!()
    assert report.status == "idle"

    assert event_types(report) == [
             "run_created",
             "agent_process_started",
             "agent_initialized",
             "agent_session_started",
             "turn_started",
             "user_message",
             "agent_message_chunk",
             "turn_finished"
           ]
  end

  test "can auto-resolve permission requests" do
    assert {:ok, report} =
             AgentProbe.run(
               agent: "stub-acp",
               workspace: File.cwd!(),
               prompt: "permission",
               resolve_permissions: "deny",
               timeout: 5_000
             )

    assert report.status == "idle"
    assert "permission_requested" in event_types(report)
    assert "permission_resolved" in event_types(report)
    assert Enum.any?(report.events, &permission_denied?/1)
  end

  defp event_types(report), do: Enum.map(report.events, & &1.type)

  defp permission_denied?(%{type: "permission_resolved", payload: payload}) do
    payload["option_id"] == "deny" and payload["actor"] == "local_user"
  end

  defp permission_denied?(_event), do: false
end
