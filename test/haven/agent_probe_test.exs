defmodule Haven.AgentProbeTest do
  use Haven.DataCase

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Haven.AgentProbe
  alias Haven.Runs
  alias Mix.Tasks.Haven.AgentProbe, as: AgentProbeTask

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

  test "redacts sensitive values from aggregate load probe reports" do
    secret = "load-secret-#{System.unique_integer([:positive])}"

    assert {:ok, report} =
             AgentProbe.run_load(
               agent: "stub-acp",
               workspace: File.cwd!(),
               prompt: "echo #{secret}",
               load_runs: 2,
               load_concurrency: 2,
               expect_events: ["agent_initialized", "turn_finished"],
               redact: secret,
               timeout: 5_000
             )

    on_exit(fn ->
      Enum.each(report.reports, &Runs.stop_run(&1.run_id))
    end)

    encoded = Jason.encode!(report)
    refute encoded =~ secret
    assert encoded =~ "[REDACTED]"
    assert report.prompt == "echo [REDACTED]"
    assert report.redactions == [%{source: "literal"}]
    assert Enum.all?(report.reports, &(&1.redactions == [%{source: "literal"}]))
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
      "missing" => %{executable: "haven-definitely-missing-agent"},
      "missing-cwd" => %{executable: "sh", cwd: "/definitely/missing/haven-cwd"}
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
    assert inventory["missing"].error == "Missing executable: haven-definitely-missing-agent"
    refute inventory["missing"].real_agent_candidate

    assert inventory["missing"].real_agent_rejection_reasons == [
             "agent executable cannot be resolved"
           ]

    assert inventory["missing-cwd"].status == "invalid"

    assert inventory["missing-cwd"].error ==
             "Missing working directory: /definitely/missing/haven-cwd"

    refute inventory["missing-cwd"].real_agent_candidate

    assert inventory["missing-cwd"].real_agent_rejection_reasons == [
             "agent working directory does not exist"
           ]

    refute Jason.encode!(inventory) =~ "hidden-value"
  end

  test "agent probe inventory task suppresses debug logs by default and restores logger level" do
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    Application.put_env(:haven, :agents, %{
      "candidate" => %{executable: "sh", args: ["-c", "cat"]}
    })

    log =
      capture_log([level: :debug], fn ->
        output =
          capture_io(fn ->
            AgentProbeTask.run(["--list-agents", "--workspace", File.cwd!()])
          end)

        assert output =~ "Configured agents:"
        assert output =~ "candidate"
        refute output =~ "QUERY OK"
      end)

    refute log =~ "QUERY OK"
    assert Logger.level() == :debug
  end

  test "agent probe inventory prints production proof commands for candidates" do
    Application.put_env(:haven, :agents, %{
      "candidate" => %{
        executable: "sh",
        args: ["-c", "cat"],
        env: %{"API_TOKEN" => "hidden-token", "MODE" => "test"}
      }
    })

    output =
      capture_io(fn ->
        AgentProbeTask.run(["--list-agents", "--proof-commands", "--workspace", File.cwd!()])
      end)

    assert output =~ "proof commands:"
    assert output =~ "redaction: commands include --redact-env for configured env keys"
    assert output =~ "basic: mix haven.agent_probe --agent candidate"
    assert output =~ "--report docs/probes/candidate-basic.json"
    assert output =~ "--redact-env API_TOKEN --redact-env MODE"
    refute output =~ "hidden-token"

    assert output =~ "file-read: mix haven.agent_probe --agent candidate"
    assert output =~ "--file-read-policy allow"
    assert output =~ "file_read_succeeded:payload.path=README.md"
    assert output =~ "--report docs/probes/candidate-file-read.json"
    assert output =~ "--failure-report docs/probe-failures/candidate-file-mediated-negative.json"

    assert output =~ "file-write-approval: mix haven.agent_probe --agent candidate"
    assert output =~ "--file-write-policy ask"
    assert output =~ "--resolve-permissions allow"
    assert output =~ "file_write_requested:payload.path=notes/haven-probe.txt"

    assert output =~
             "--failure-report docs/probe-failures/candidate-file-write-mediated-negative.json"

    assert output =~ "terminal-approval: mix haven.agent_probe --agent candidate"
    assert output =~ "--terminal-create-policy ask"
    assert output =~ "terminal_output_succeeded:payload.exit_status=0"

    assert output =~
             "--failure-report docs/probe-failures/candidate-terminal-mediated-negative.json"

    assert output =~ "terminal-denied: mix haven.agent_probe --agent candidate"

    assert output =~
             "--prompt 'run mix --version through the client terminal capability' --terminal-create-policy deny"

    assert output =~ "--terminal-create-policy deny"
    assert output =~ "capability_policy_applied:payload.decision=deny"

    assert output =~
             "--failure-report docs/probe-failures/candidate-terminal-denied-mediated-negative.json"

    assert output =~ "long-output: mix haven.agent_probe --agent candidate"
    assert output =~ "--expect-min-agent-output-chars 1200"
    assert output =~ "--expect-min-agent-message-chunks 8"
    assert output =~ "--report docs/probes/candidate-long-output.json"

    assert output =~ "load-concurrent: mix haven.agent_probe --agent candidate"
    assert output =~ "--load-runs 3"
    assert output =~ "--load-concurrency 3"
    assert output =~ "--report docs/probe-load/candidate-basic-concurrent-load.json"
  end

  test "agent probe inventory keeps production proof commands on demand" do
    Application.put_env(:haven, :agents, %{
      "candidate" => %{executable: "sh", args: ["-c", "cat"]}
    })

    output =
      capture_io(fn ->
        AgentProbeTask.run(["--list-agents", "--workspace", File.cwd!()])
      end)

    assert output =~ "proof commands: hidden (add --proof-commands"
    refute output =~ "file-read: mix haven.agent_probe --agent candidate"
    refute output =~ "terminal-approval: mix haven.agent_probe --agent candidate"
  end

  test "agent probe inventory prints committed capability gap families" do
    Application.put_env(:haven, :agents, %{
      "codex-acp" => %{executable: "sh", args: ["-c", "cat"]}
    })

    output =
      capture_io(fn ->
        AgentProbeTask.run(["--list-agents", "--workspace", File.cwd!()])
      end)

    assert output =~
             "committed capability gaps: fs/read_text_file/fs/write_text_file/terminal (3 reports)"

    assert output =~
             "docs/probe-failures/codex-acp-file-mediated-negative.json: fs/read_text_file"

    assert output =~
             "docs/probe-failures/codex-acp-file-write-mediated-negative.json: fs/write_text_file"

    assert output =~
             "docs/probe-failures/codex-acp-terminal-mediated-negative.json: terminal"
  end

  test "agent probe inventory preflight prints a concise candidate summary" do
    Application.put_env(:haven, :agents, %{
      "not-acp" => %{executable: "sh", args: ["-c", "cat"]}
    })

    output =
      capture_io(fn ->
        AgentProbeTask.run([
          "--list-agents",
          "--preflight",
          "--workspace",
          File.cwd!(),
          "--timeout",
          "1000"
        ])
      end)

    assert output =~ "not-acp"
    assert output =~ "preflight: failed"

    assert output =~
             "Preflight summary: 0/1 candidate passed ACP initialize/session handshake; 1 failed."

    refute output =~ "Preflight-ready agents:"
    assert output =~ "Preflight-failed agents: not-acp (boot_failed)"
  end

  test "agent probe inventory withholds proof commands when preflight fails" do
    Application.put_env(:haven, :agents, %{
      "not-acp" => %{executable: "sh", args: ["-c", "cat"]}
    })

    output =
      capture_io(fn ->
        AgentProbeTask.run([
          "--list-agents",
          "--preflight",
          "--proof-commands",
          "--workspace",
          File.cwd!(),
          "--timeout",
          "1000"
        ])
      end)

    assert output =~ "not-acp"
    assert output =~ "preflight: failed"

    assert output =~
             "proof commands: withheld because preflight failed; fix ACP initialize/session before running full probes"

    refute output =~ "file-read: mix haven.agent_probe --agent not-acp"
    refute output =~ "terminal-approval: mix haven.agent_probe --agent not-acp"
  end

  test "agent probe task prints event summaries by default" do
    output =
      capture_io(fn ->
        AgentProbeTask.run([
          "--agent",
          "stub-acp",
          "--workspace",
          File.cwd!(),
          "--prompt",
          "hello from task",
          "--expect-event",
          "turn_finished",
          "--timeout",
          "5000"
        ])
      end)

    assert output =~ "Event summary:"
    assert output =~ "turn_finished=1"
    assert output =~ "Use --show-events to print full event payloads."
    refute output =~ "1. run_created"
  end

  test "agent probe task can print full event payloads on request" do
    output =
      capture_io(fn ->
        AgentProbeTask.run([
          "--agent",
          "stub-acp",
          "--workspace",
          File.cwd!(),
          "--prompt",
          "hello from task",
          "--expect-event",
          "turn_finished",
          "--show-events",
          "--timeout",
          "5000"
        ])
      end)

    assert output =~ "Events:"
    assert output =~ "1. run_created"
    assert output =~ "turn_finished"
    refute output =~ "Use --show-events"
  end

  test "load probe task prints aggregate summaries by default" do
    output =
      capture_io(fn ->
        AgentProbeTask.run([
          "--agent",
          "stub-acp",
          "--workspace",
          File.cwd!(),
          "--prompt",
          "hello from load task",
          "--load-runs",
          "2",
          "--load-concurrency",
          "2",
          "--expect-event",
          "agent_initialized",
          "--expect-event",
          "turn_finished",
          "--timeout",
          "5000"
        ])
      end)

    assert output =~ "Load probe: 2 run(s)"
    assert output =~ "Run summary: idle=2"
    assert output =~ "Child event summary:"
    assert output =~ "agent_initialized=2"
    assert output =~ "turn_finished=2"
    assert output =~ "Use --show-events to print full child event payloads."
    refute output =~ "  1. run_created"
  end

  test "load probe task can print full child event payloads on request" do
    output =
      capture_io(fn ->
        AgentProbeTask.run([
          "--agent",
          "stub-acp",
          "--workspace",
          File.cwd!(),
          "--prompt",
          "hello from load task",
          "--load-runs",
          "2",
          "--load-concurrency",
          "2",
          "--expect-event",
          "turn_finished",
          "--show-events",
          "--timeout",
          "5000"
        ])
      end)

    assert output =~ "Load probe: 2 run(s)"
    assert output =~ "  1. run_created"
    assert output =~ "turn_finished"
  end

  test "agent probe task prints unsupported mediated capability summaries" do
    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/Agent probe failed: missing_expected_events/, fn ->
          AgentProbeTask.run([
            "--agent",
            "stub-acp",
            "--workspace",
            File.cwd!(),
            "--prompt",
            "unknown-update",
            "--expect-event",
            "file_read_succeeded",
            "--timeout",
            "5000"
          ])
        end
      end)

    assert output =~ "Unsupported mediated capabilities:"

    assert output =~
             "fs/read_text_file: missing file_read_succeeded; observed tool_call_update"

    assert output =~ "Diagnostics:"
    assert output =~ "Expected Haven-mediated client capability events were missing"
  end

  @tag :tmp_dir
  test "agent probe task writes failed probes to a separate failure report path", %{
    tmp_dir: tmp_dir
  } do
    positive_path = Path.join(tmp_dir, "positive.json")
    failure_path = Path.join(tmp_dir, "failure.json")

    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/Agent probe failed: missing_expected_events/, fn ->
          AgentProbeTask.run([
            "--agent",
            "stub-acp",
            "--workspace",
            File.cwd!(),
            "--prompt",
            "unknown-update",
            "--expect-event",
            "file_read_succeeded",
            "--report",
            positive_path,
            "--failure-report",
            failure_path,
            "--timeout",
            "5000"
          ])
        end
      end)

    assert output =~ "Report written: #{failure_path}"
    refute File.exists?(positive_path)
    assert File.exists?(failure_path)

    assert {:ok, report} =
             failure_path
             |> File.read!()
             |> Jason.decode()

    assert report["missing_expected_events"] == ["file_read_succeeded"]
    assert [%{"capability" => "fs/read_text_file"}] = report["unsupported_client_capabilities"]
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

  test "runs a load probe as multiple durable runs" do
    assert {:ok, report} =
             AgentProbe.run_load(
               agent: "stub-acp",
               workspace: File.cwd!(),
               prompt: "hello from load probe",
               load_runs: 2,
               load_concurrency: 2,
               expect_events: ["agent_initialized", "turn_finished"],
               timeout: 5_000
             )

    on_exit(fn ->
      Enum.each(report.reports, &Runs.stop_run(&1.run_id))
    end)

    assert report.kind == "agent_probe_load"
    assert report.status == "passed"
    assert report.run_count == 2
    assert report.concurrency == 2
    assert report.expected_events == ["agent_initialized", "turn_finished"]
    assert report.failures == []
    assert length(report.reports) == 2
    assert length(report.child_windows) == 2
    assert Enum.all?(report.child_windows, &(&1.status == "idle"))

    run_ids = Enum.map(report.reports, & &1.run_id)
    assert Enum.uniq(run_ids) == run_ids
    assert Enum.all?(report.reports, &(&1.status == "idle"))
  end

  test "rejects invalid load run counts" do
    assert {:error, :invalid_load_runs, report} =
             AgentProbe.run_load(agent: "stub-acp", workspace: File.cwd!(), load_runs: 1)

    assert report.kind == "agent_probe_load"
    assert report.status == "failed"
    assert report.run_count == 1
    assert report.reports == []
    assert [%{reason: :invalid_load_runs}] = report.failures
  end

  test "rejects invalid load concurrency" do
    assert {:error, :invalid_load_concurrency, report} =
             AgentProbe.run_load(
               agent: "stub-acp",
               workspace: File.cwd!(),
               load_runs: 2,
               load_concurrency: 3
             )

    assert report.kind == "agent_probe_load"
    assert report.status == "failed"
    assert report.run_count == 2
    assert report.concurrency == 3
    assert report.reports == []
    assert [%{reason: :invalid_load_concurrency}] = report.failures
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

  test "agent inventory includes the latest durable preflight result for the workspace" do
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

    inventory =
      File.cwd!()
      |> AgentProbe.agent_inventory()
      |> Map.new(&{&1.agent, &1})

    assert %{
             status: "failed",
             run_id: run_id,
             run_status: "failed",
             last_event_type: "agent_protocol_failed",
             failure_reason: reason
           } = inventory["not-acp"].latest_preflight

    assert run_id == report.run_id
    assert reason =~ "Method not found"
  end

  test "agent probe inventory prints the latest durable preflight before rerun" do
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

    output =
      capture_io(fn ->
        AgentProbeTask.run(["--list-agents", "--workspace", File.cwd!()])
      end)

    assert output =~ "latest durable preflight: failed (run #{report.run_id})"
    assert output =~ "latest durable preflight reason:"
    assert output =~ "preflight: not run"
  end

  test "agent probe inventory withholds proof commands after a failed durable preflight" do
    Application.put_env(:haven, :agents, %{
      "not-acp" => %{executable: "sh", args: ["-c", "cat"]}
    })

    assert {:error, :boot_failed, _report} =
             AgentProbe.preflight(
               agent: "not-acp",
               workspace: File.cwd!(),
               timeout: 1_000,
               require_real_agent: true
             )

    output =
      capture_io(fn ->
        AgentProbeTask.run([
          "--list-agents",
          "--proof-commands",
          "--workspace",
          File.cwd!()
        ])
      end)

    assert output =~ "latest durable preflight: failed"

    assert output =~
             "proof commands: withheld because latest durable preflight failed; rerun --preflight after fixing ACP initialize/session before running full probes"

    refute output =~ "basic: mix haven.agent_probe --agent not-acp"
    refute output =~ "terminal-denied: mix haven.agent_probe --agent not-acp"
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

  test "diagnoses tool-call-only activity when Haven-mediated capability events are missing" do
    assert {:error, :missing_expected_events, report} =
             AgentProbe.run(
               agent: "stub-acp",
               workspace: File.cwd!(),
               prompt: "unknown-update",
               expect_events: ["file_read_succeeded"],
               timeout: 5_000
             )

    assert report.missing_expected_events == ["file_read_succeeded"]

    assert [
             %{
               type: "tool_call_only_capability_gap",
               missing_events: ["file_read_succeeded"],
               observed_events: ["tool_call_update"]
             }
           ] = report.diagnostics

    assert [
             %{
               capability: "fs/read_text_file",
               missing_events: ["file_read_succeeded"],
               observed_events: ["tool_call_update"]
             }
           ] = report.unsupported_client_capabilities
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

  test "passes when expected agent output minimums are met" do
    assert {:ok, report} =
             AgentProbe.run(
               agent: "stub-acp",
               workspace: File.cwd!(),
               prompt: "hello from probe",
               expect_min_agent_output_chars: 5,
               expect_min_agent_message_chunks: 1,
               timeout: 5_000
             )

    assert report.agent_output_metrics.text_char_count >= 5
    assert report.agent_output_metrics.message_chunk_count >= 1

    assert report.expected_output == %{
             "min_agent_output_chars" => 5,
             "min_agent_message_chunks" => 1
           }

    assert report.missing_expected_output == []
  end

  test "fails when expected agent output minimums are absent" do
    assert {:error, :missing_expected_output, report} =
             AgentProbe.run(
               agent: "stub-acp",
               workspace: File.cwd!(),
               prompt: "hello from probe",
               expect_min_agent_output_chars: 10_000,
               expect_min_agent_message_chunks: 100,
               timeout: 5_000
             )

    assert [
             %{metric: :min_agent_message_chunks, expected: 100},
             %{metric: :min_agent_output_chars, expected: 10_000}
           ] = report.missing_expected_output
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
