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

  test "can create probe runs with file capability policy" do
    assert {:ok, report} =
             AgentProbe.run(
               agent: "stub-acp",
               workspace: File.cwd!(),
               prompt: "read-file",
               file_read_policy: "allow",
               timeout: 5_000,
               expect_events: ["capability_policy_applied", "file_read_succeeded"]
             )

    assert report.status == "idle"
    assert report.missing_expected_events == []
    assert "permission_requested" not in event_types(report)

    assert Enum.any?(report.events, fn
             %{type: "capability_policy_applied", payload: payload} ->
               payload["capability"] == "file_read" and payload["decision"] == "allow"

             _event ->
               false
           end)
  end

  test "can create probe runs with terminal creation denied by policy" do
    assert {:ok, report} =
             AgentProbe.run(
               agent: "stub-acp",
               workspace: File.cwd!(),
               prompt: "terminal",
               terminal_create_policy: "deny",
               timeout: 5_000,
               expect_events: [
                 "terminal_create_requested",
                 "capability_policy_applied",
                 "terminal_create_denied",
                 "turn_finished"
               ]
             )

    assert report.status == "idle"
    assert report.missing_expected_events == []
    assert "terminal_created" not in event_types(report)

    assert Enum.any?(report.events, fn
             %{type: "capability_policy_applied", payload: payload} ->
               payload["capability"] == "terminal_create" and payload["decision"] == "deny"

             _event ->
               false
           end)
  end

  test "passes when expected events are present" do
    assert {:ok, report} =
             AgentProbe.run(
               agent: "stub-acp",
               workspace: File.cwd!(),
               prompt: "hello from probe",
               expect_events: ["agent_initialized", "turn_finished"],
               timeout: 5_000
             )

    assert report.missing_expected_events == []
    assert report.expected_events == ["agent_initialized", "turn_finished"]
  end

  test "fails when expected events are missing" do
    assert {:error, :missing_expected_events, report} =
             AgentProbe.run(
               agent: "stub-acp",
               workspace: File.cwd!(),
               prompt: "hello from probe",
               expect_events: ["file_read_succeeded", "terminal_created"],
               timeout: 5_000
             )

    assert report.status == "idle"
    assert report.expected_events == ["file_read_succeeded", "terminal_created"]
    assert report.missing_expected_events == ["file_read_succeeded", "terminal_created"]
    assert "turn_finished" in event_types(report)
  end

  defp event_types(report), do: Enum.map(report.events, & &1.type)

  defp permission_denied?(%{type: "permission_resolved", payload: payload}) do
    payload["option_id"] == "deny" and payload["actor"] == "local_user"
  end

  defp permission_denied?(_event), do: false
end
