defmodule Haven.AgentProbeTest do
  use Haven.DataCase

  alias Haven.AgentProbe

  setup do
    original = Application.get_env(:haven, :agents)

    on_exit(fn ->
      if original do
        Application.put_env(:haven, :agents, original)
      else
        Application.delete_env(:haven, :agents)
      end
    end)
  end

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

  test "redacts literal sensitive values from probe reports" do
    secret = "literal-secret-#{System.unique_integer([:positive])}"

    assert {:ok, report} =
             AgentProbe.run(
               agent: "stub-acp",
               workspace: File.cwd!(),
               prompt: "echo #{secret}",
               redact: secret,
               timeout: 5_000
             )

    encoded = Jason.encode!(report)
    refute encoded =~ secret
    assert encoded =~ "[REDACTED]"
    assert report.prompt == "echo [REDACTED]"
    assert report.redactions == [%{source: "literal"}]
  end

  test "redacts values read from environment variables" do
    name = "HAVEN_AGENT_PROBE_SECRET"
    secret = "env-secret-#{System.unique_integer([:positive])}"
    System.put_env(name, secret)
    on_exit(fn -> System.delete_env(name) end)

    assert {:ok, report} =
             AgentProbe.run(
               agent: "stub-acp",
               workspace: File.cwd!(),
               prompt: "echo #{secret}",
               redact_env: name,
               timeout: 5_000
             )

    encoded = Jason.encode!(report)
    refute encoded =~ secret
    assert encoded =~ "[REDACTED]"
    assert report.redactions == [%{source: "env", name: name}]
  end

  test "can require real-agent evidence and reject the built-in stub" do
    assert {:error, :real_agent_required, report} =
             AgentProbe.run(
               agent: "stub-acp",
               workspace: File.cwd!(),
               prompt: "hello from probe",
               timeout: 5_000,
               require_real_agent: true
             )

    assert report.real_agent_evidence == %{
             accepted: false,
             reasons: ["agent is built-in stub-acp", "agent command uses a local test harness"],
             required: true
           }

    assert report.errors == %{
             "real_agent" => [
               "agent is built-in stub-acp",
               "agent command uses a local test harness"
             ]
           }
  end

  test "can require real-agent evidence and reject the configured test harness" do
    Application.put_env(:haven, :agents, %{
      "fake-probe-streaming" => fake_agent_spec("streaming")
    })

    assert {:error, :real_agent_required, report} =
             AgentProbe.run(
               agent: "fake-probe-streaming",
               workspace: File.cwd!(),
               prompt: "partial-stream",
               timeout: 5_000,
               require_real_agent: true
             )

    assert report.real_agent_evidence == %{
             accepted: false,
             reasons: ["agent command uses a local test harness"],
             required: true
           }

    assert report.errors == %{"real_agent" => ["agent command uses a local test harness"]}
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

  test "probes file reads through a configured external ACP command" do
    Application.put_env(:haven, :agents, %{
      "fake-probe-file-read" => fake_agent_spec("file-read")
    })

    assert {:ok, report} =
             AgentProbe.run(
               agent: "fake-probe-file-read",
               workspace: File.cwd!(),
               prompt: "read-file",
               file_read_policy: "allow",
               timeout: 5_000,
               expect_events: [
                 "agent_initialized",
                 "agent_session_started",
                 "file_read_requested",
                 "capability_policy_applied",
                 "file_read_succeeded",
                 "turn_finished"
               ]
             )

    assert report.status == "idle"
    assert report.missing_expected_events == []
    assert report.agent == "fake-probe-file-read"

    assert Enum.any?(report.events, fn
             %{type: "agent_message_chunk", payload: %{"text" => text}} ->
               String.starts_with?(text, "Fake read file:")

             _event ->
               false
           end)
  end

  test "probes terminal commands through a configured external ACP command" do
    Application.put_env(:haven, :agents, %{
      "fake-probe-terminal" => fake_agent_spec("terminal")
    })

    assert {:ok, report} =
             AgentProbe.run(
               agent: "fake-probe-terminal",
               workspace: File.cwd!(),
               prompt: "terminal",
               terminal_create_policy: "allow",
               timeout: 5_000,
               expect_events: [
                 "agent_initialized",
                 "agent_session_started",
                 "terminal_create_requested",
                 "terminal_created",
                 "terminal_output_succeeded",
                 "terminal_released",
                 "turn_finished"
               ]
             )

    assert report.status == "idle"
    assert report.missing_expected_events == []
    assert report.agent == "fake-probe-terminal"

    assert Enum.any?(report.events, fn
             %{type: "agent_message_chunk", payload: %{"text" => text}} ->
               text == "Fake terminal output: external (exit 0)"

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

  defp fake_agent_spec(scenario) do
    %{
      executable: System.find_executable("mix"),
      args: [
        "run",
        "--no-compile",
        "--no-start",
        "test/support/fake_agent_runner.exs",
        scenario,
        "{workspace}"
      ],
      cwd: "{workspace}",
      env: [{"MIX_ENV", "test"}]
    }
  end

  defp permission_denied?(%{type: "permission_resolved", payload: payload}) do
    payload["option_id"] == "deny" and payload["actor"] == "local_user"
  end

  defp permission_denied?(_event), do: false
end
