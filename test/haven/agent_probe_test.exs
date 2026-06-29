defmodule Haven.AgentProbeTest do
  use Haven.DataCase

  alias Haven.AgentProbe
  alias Haven.Runs

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

  test "lists configured agent readiness for real-agent evidence" do
    sh = System.find_executable("sh")

    Application.put_env(:haven, :agents, %{
      "candidate" => %{
        executable: "sh",
        args: ["-c", "cat"],
        cwd: "{workspace}",
        env: %{"SECRET" => "hidden-value", "WORKSPACE" => "{workspace}"}
      },
      "fake-probe-streaming" => fake_agent_spec("streaming"),
      "malformed-local" => %{executable: "sh", args: ["priv/malformed_agent.exs"]},
      "missing" => %{executable: "haven-definitely-missing-agent"}
    })

    inventory =
      File.cwd!()
      |> AgentProbe.agent_inventory()
      |> Map.new(&{&1.agent, &1})

    assert inventory["candidate"] == %{
             agent: "candidate",
             status: "ready",
             executable: sh,
             args: ["-c", "cat"],
             cwd: File.cwd!(),
             env_keys: ["SECRET", "WORKSPACE"],
             real_agent_candidate: true,
             real_agent_rejection_reasons: []
           }

    assert inventory["fake-probe-streaming"].status == "ready"
    refute inventory["fake-probe-streaming"].real_agent_candidate

    assert inventory["fake-probe-streaming"].real_agent_rejection_reasons == [
             "agent command uses a local test harness"
           ]

    assert inventory["malformed-local"].status == "ready"
    refute inventory["malformed-local"].real_agent_candidate

    assert inventory["malformed-local"].real_agent_rejection_reasons == [
             "agent command uses a local test harness"
           ]

    assert inventory["missing"].status == "invalid"
    refute inventory["missing"].real_agent_candidate

    assert inventory["missing"].real_agent_rejection_reasons == [
             "agent command cannot be resolved"
           ]

    refute Jason.encode!(inventory) =~ "hidden-value"
  end

  test "preflights an ACP agent without sending a prompt" do
    assert {:ok, report} =
             AgentProbe.preflight(
               agent: "stub-acp",
               workspace: File.cwd!(),
               timeout: 5_000
             )

    assert report.agent == "stub-acp"
    assert report.status == "idle"

    assert event_types(report) == [
             "run_created",
             "agent_process_started",
             "agent_initialized",
             "agent_session_started"
           ]

    refute Runs.started?(report.run_id)
  end

  test "preflight surfaces non-ACP commands before full evidence probes" do
    Application.put_env(:haven, :agents, %{
      "not-acp" => %{executable: "sh", args: ["-c", "cat"]}
    })

    assert {:error, :boot_failed, report} =
             AgentProbe.preflight(
               agent: "not-acp",
               workspace: File.cwd!(),
               timeout: 1_000,
               require_real_agent: true
             )

    assert report.agent == "not-acp"
    assert report.status == "failed"
    assert "agent_initialized" not in event_types(report)

    assert Enum.any?(report.events, fn
             %{type: "agent_protocol_failed", payload: %{"reason" => reason}} ->
               reason =~ "Method not found"

             _event ->
               false
           end)
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

  test "can create probe runs with scoped file capability policy" do
    assert {:ok, report} =
             AgentProbe.run(
               agent: "stub-acp",
               workspace: File.cwd!(),
               prompt: "read-file",
               file_read_policy: "allow",
               file_read_paths: ["docs"],
               timeout: 5_000,
               expect_events: [
                 "file_read_requested",
                 "capability_policy_applied",
                 "file_read_denied",
                 "turn_finished"
               ]
             )

    assert report.status == "idle"
    assert report.missing_expected_events == []
    assert "permission_requested" not in event_types(report)
    assert "file_read_succeeded" not in event_types(report)

    assert Enum.any?(report.events, fn
             %{type: "run_created", payload: %{"capability_policy" => policy}} ->
               policy["file_read_paths"] == ["docs"] and
                 not Map.has_key?(policy, "file_write_paths")

             _event ->
               false
           end)

    assert Enum.any?(report.events, fn
             %{type: "capability_policy_applied", payload: payload} ->
               payload["capability"] == "file_read" and
                 payload["decision"] == "deny" and
                 payload["reason"] == "path_scope"

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

  test "probes approval-gated terminal commands through a configured external ACP command" do
    Application.put_env(:haven, :agents, %{
      "fake-probe-terminal-ask" => fake_agent_spec("terminal")
    })

    assert {:ok, report} =
             AgentProbe.run(
               agent: "fake-probe-terminal-ask",
               workspace: File.cwd!(),
               prompt: "terminal",
               terminal_create_policy: "ask",
               resolve_permissions: "allow",
               timeout: 5_000,
               expect_events: [
                 "agent_initialized",
                 "agent_session_started",
                 "terminal_create_requested",
                 "permission_requested",
                 "permission_resolved",
                 "terminal_created",
                 "terminal_output_succeeded",
                 "turn_finished"
               ]
             )

    assert report.status == "idle"
    assert report.missing_expected_events == []
    assert report.agent == "fake-probe-terminal-ask"

    assert Enum.any?(report.events, fn
             %{type: "permission_requested", payload: %{"toolCall" => %{"title" => title}}} ->
               title == "Create terminal"

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

  test "passes when expected event payload fields are present" do
    assert {:ok, report} =
             AgentProbe.run(
               agent: "stub-acp",
               workspace: File.cwd!(),
               prompt: "terminal",
               terminal_create_policy: "deny",
               expect_events: ["terminal_create_denied"],
               expect_event_field: "terminal_create_denied:payload.command=echo",
               expect_event_fields: [
                 %{event: "capability_policy_applied", field: "payload.decision", value: "deny"}
               ],
               timeout: 5_000
             )

    assert report.missing_expected_event_fields == []

    assert report.expected_event_fields == [
             %{event: "terminal_create_denied", field: "command", value: "echo"},
             %{event: "capability_policy_applied", field: "decision", value: "deny"}
           ]
  end

  test "fails when expected event payload fields are absent" do
    assert {:error, :missing_expected_event_fields, report} =
             AgentProbe.run(
               agent: "stub-acp",
               workspace: File.cwd!(),
               prompt: "terminal",
               terminal_create_policy: "deny",
               expect_event_field: "terminal_create_denied:command=not-echo",
               timeout: 5_000
             )

    assert report.status == "idle"

    assert report.missing_expected_event_fields == [
             %{event: "terminal_create_denied", field: "command", value: "not-echo"}
           ]
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
