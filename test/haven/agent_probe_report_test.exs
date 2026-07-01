defmodule Haven.AgentProbeReportTest do
  use ExUnit.Case, async: true

  alias Haven.AgentProbeReport

  test "accepts a real-agent probe report with required events present" do
    assert :ok = AgentProbeReport.validate(valid_report())
  end

  test "rejects reports without real-agent acceptance metadata" do
    report = Map.delete(valid_report(), "real_agent_evidence")

    assert {:error, errors} = AgentProbeReport.validate(report)
    assert "real_agent_evidence must have required=true and accepted=true" in errors
  end

  test "rejects reports without redaction metadata" do
    report = Map.delete(valid_report(), "redactions")

    assert {:error, errors} = AgentProbeReport.validate(report)
    assert "redactions must be a list" in errors
  end

  test "accepts safe literal and environment redaction metadata" do
    report =
      valid_report()
      |> Map.put("redactions", [
        %{"source" => "literal"},
        %{"source" => "env", "name" => "ANTHROPIC_API_KEY"}
      ])

    assert :ok = AgentProbeReport.validate(report)
  end

  test "rejects redaction metadata that leaks raw values" do
    report =
      valid_report()
      |> Map.put("redactions", [
        %{"source" => "literal", "value" => "secret"},
        %{"source" => "env", "name" => "TOKEN", "value" => "secret"}
      ])

    assert {:error, errors} = AgentProbeReport.validate(report)
    assert "redactions entry 1 must not include raw secret value" in errors
    assert "redactions entry 2 must not include raw secret value" in errors
  end

  test "rejects malformed environment redaction metadata" do
    report =
      valid_report()
      |> Map.put("redactions", [
        %{"source" => "env", "name" => "   "},
        %{"source" => "other"}
      ])

    assert {:error, errors} = AgentProbeReport.validate(report)
    assert "redactions entry 1 env name must be a non-empty string" in errors
    assert "redactions entry 2 must be literal or env metadata without secret values" in errors
  end

  test "rejects reports without a durable run id" do
    report = Map.delete(valid_report(), "run_id")

    assert {:error, errors} = AgentProbeReport.validate(report)
    assert "run_id must be a non-empty string" in errors
  end

  test "rejects reports with whitespace-only required metadata" do
    report =
      valid_report()
      |> Map.put("run_id", "   ")
      |> Map.put("agent", "   ")
      |> Map.put("workspace", "   ")
      |> Map.put("prompt", "   ")

    assert {:error, errors} = AgentProbeReport.validate(report)
    assert "run_id must be a non-empty string" in errors
    assert "agent must be a non-empty string" in errors
    assert "workspace must be a non-empty string" in errors
    assert "prompt must be a non-empty string" in errors
  end

  test "rejects stub reports" do
    report = Map.put(valid_report(), "agent", "stub-acp")

    assert {:error, errors} = AgentProbeReport.validate(report)
    assert "agent must not be stub-acp" in errors
  end

  test "rejects reports with missing expected events" do
    report =
      valid_report()
      |> Map.put("expected_events", ["turn_finished", "terminal_created"])
      |> Map.put("missing_expected_events", ["terminal_created"])

    assert {:error, errors} = AgentProbeReport.validate(report)
    assert "missing_expected_events must be empty" in errors
    assert "expected events are absent from events: terminal_created" in errors
  end

  test "rejects reports without the full Haven run lifecycle" do
    report =
      valid_report()
      |> Map.put("events", [
        %{"seq" => 1, "type" => "run_created", "payload" => %{}},
        %{"seq" => 2, "type" => "agent_initialized", "payload" => %{}},
        %{"seq" => 3, "type" => "turn_finished", "payload" => %{"stopReason" => "end_turn"}}
      ])

    assert {:error, errors} = AgentProbeReport.validate(report)

    assert "events must include full Haven run lifecycle: agent_process_started, agent_session_started, turn_started, user_message" in errors
  end

  test "rejects reports whose run_created event does not match report metadata" do
    report =
      valid_report()
      |> update_event("run_created", fn event ->
        put_in(event, ["payload", "agent"], "other-agent")
      end)

    assert {:error, errors} = AgentProbeReport.validate(report)
    assert "run_created payload agent must match report metadata" in errors
  end

  test "rejects reports whose run_created workspace does not match report metadata" do
    report =
      valid_report()
      |> update_event("run_created", fn event ->
        put_in(event, ["payload", "workspace"], "/other-workspace")
      end)

    assert {:error, errors} = AgentProbeReport.validate(report)
    assert "run_created payload workspace must match report metadata" in errors
  end

  test "rejects reports whose user message does not match the report prompt" do
    report =
      valid_report()
      |> update_event("user_message", fn event ->
        put_in(event, ["payload", "text"], "different prompt")
      end)

    assert {:error, errors} = AgentProbeReport.validate(report)
    assert "user_message payload text must match report metadata" in errors
  end

  test "accepts reports with matching expected event fields" do
    report =
      valid_report()
      |> Map.put("expected_event_fields", [
        %{"event" => "turn_finished", "field" => "stopReason", "value" => "end_turn"}
      ])

    assert :ok = AgentProbeReport.validate(report)
  end

  test "accepts documented payload-prefixed expected event fields" do
    report =
      valid_report()
      |> Map.put("expected_event_fields", [
        %{"event" => "turn_finished", "field" => "payload.stopReason", "value" => "end_turn"}
      ])

    assert :ok = AgentProbeReport.validate(report)
  end

  test "rejects reports with missing expected event fields" do
    report =
      valid_report()
      |> Map.put("expected_event_fields", [
        %{"event" => "turn_finished", "field" => "stopReason", "value" => "interrupted"}
      ])
      |> Map.put("missing_expected_event_fields", [
        %{"event" => "turn_finished", "field" => "stopReason", "value" => "interrupted"}
      ])

    assert {:error, errors} = AgentProbeReport.validate(report)
    assert "missing_expected_event_fields must be empty" in errors

    assert "expected event fields are absent from events: turn_finished:stopReason=interrupted" in errors
  end

  test "reports missing payload-prefixed expected event fields using the original field" do
    report =
      valid_report()
      |> Map.put("expected_event_fields", [
        %{"event" => "turn_finished", "field" => "payload.stopReason", "value" => "interrupted"}
      ])
      |> Map.put("missing_expected_event_fields", [
        %{"event" => "turn_finished", "field" => "payload.stopReason", "value" => "interrupted"}
      ])

    assert {:error, errors} = AgentProbeReport.validate(report)

    assert "expected event fields are absent from events: turn_finished:payload.stopReason=interrupted" in errors
  end

  test "accepts client capability reports with matching expected event fields" do
    report =
      valid_report()
      |> Map.put("expected_events", [
        "agent_initialized",
        "terminal_output_succeeded",
        "turn_finished"
      ])
      |> Map.put("expected_event_fields", [
        %{"event" => "terminal_output_succeeded", "field" => "exit_status", "value" => "0"}
      ])
      |> Map.put("events", [
        %{
          "seq" => 1,
          "type" => "run_created",
          "payload" => %{"agent" => "real-agent", "workspace" => "/workspace"}
        },
        %{"seq" => 2, "type" => "agent_process_started", "payload" => %{}},
        %{"seq" => 3, "type" => "agent_initialized", "payload" => %{}},
        %{"seq" => 4, "type" => "agent_session_started", "payload" => %{}},
        %{"seq" => 5, "type" => "turn_started", "payload" => %{}},
        %{"seq" => 6, "type" => "user_message", "payload" => %{"text" => "summarize"}},
        %{
          "seq" => 7,
          "type" => "terminal_output_succeeded",
          "payload" => %{"exit_status" => 0}
        },
        %{"seq" => 8, "type" => "turn_finished", "payload" => %{"stopReason" => "end_turn"}}
      ])

    assert :ok = AgentProbeReport.validate(report)
  end

  test "rejects client capability reports without field-level expectations" do
    report =
      valid_report()
      |> Map.put("expected_events", [
        "agent_initialized",
        "terminal_output_succeeded",
        "turn_finished"
      ])
      |> Map.put("events", [
        %{
          "seq" => 1,
          "type" => "run_created",
          "payload" => %{"agent" => "real-agent", "workspace" => "/workspace"}
        },
        %{"seq" => 2, "type" => "agent_process_started", "payload" => %{}},
        %{"seq" => 3, "type" => "agent_initialized", "payload" => %{}},
        %{"seq" => 4, "type" => "agent_session_started", "payload" => %{}},
        %{"seq" => 5, "type" => "turn_started", "payload" => %{}},
        %{"seq" => 6, "type" => "user_message", "payload" => %{"text" => "summarize"}},
        %{
          "seq" => 7,
          "type" => "terminal_output_succeeded",
          "payload" => %{"exit_status" => 0}
        },
        %{"seq" => 8, "type" => "turn_finished", "payload" => %{"stopReason" => "end_turn"}}
      ])

    assert {:error, errors} = AgentProbeReport.validate(report)

    assert "client capability expected events require matching expected_event_fields: terminal_output_succeeded" in errors
  end

  test "rejects structurally invalid events" do
    report = Map.put(valid_report(), "events", [%{"seq" => 2, "type" => "run_created"}])

    assert {:error, errors} = AgentProbeReport.validate(report)
    assert "event 1 must include integer seq, string type, and object payload" in errors
  end

  test "rejects blank expected event names" do
    report = Map.put(valid_report(), "expected_events", ["agent_initialized", "   "])

    assert {:error, errors} = AgentProbeReport.validate(report)
    assert "expected_events must be a non-empty list of event names" in errors
  end

  test "rejects report events with blank types" do
    report =
      valid_report()
      |> Map.put("expected_events", ["agent_initialized"])
      |> Map.put("events", [
        %{"seq" => 1, "type" => "   ", "payload" => %{}},
        %{"seq" => 2, "type" => "agent_initialized", "payload" => %{}}
      ])

    assert {:error, errors} = AgentProbeReport.validate(report)
    assert "event 1 must include non-empty string type" in errors
  end

  test "rejects expected event fields with blank event or field names" do
    report =
      valid_report()
      |> Map.put("expected_event_fields", [
        %{"event" => " ", "field" => "payload.path", "value" => "README.md"},
        %{"event" => "file_read_succeeded", "field" => " ", "value" => "README.md"}
      ])

    assert {:error, errors} = AgentProbeReport.validate(report)

    assert "expected_event_fields entry 1 must include string event, field, and value" in errors
    assert "expected_event_fields entry 2 must include string event, field, and value" in errors
  end

  test "validates report files" do
    path =
      Path.join(System.tmp_dir!(), "haven-valid-probe-report-#{System.unique_integer()}.json")

    File.write!(path, Jason.encode!(valid_report()))

    assert :ok = AgentProbeReport.validate_file(path)

    File.rm(path)
  end

  test "accepts real-agent failure reports with tool-call-only capability gaps" do
    assert :ok = AgentProbeReport.validate_failure(valid_failure_report())
  end

  test "rejects failure reports without real-agent acceptance metadata" do
    report = Map.delete(valid_failure_report(), "real_agent_evidence")

    assert {:error, errors} = AgentProbeReport.validate_failure(report)
    assert "real_agent_evidence must have required=true and accepted=true" in errors
  end

  test "rejects failure reports without missing expected client capability events" do
    report =
      valid_failure_report()
      |> Map.put("expected_events", ["agent_initialized", "turn_finished"])
      |> Map.put("missing_expected_events", [])

    assert {:error, errors} = AgentProbeReport.validate_failure(report)

    assert "missing_expected_events must be a non-empty list of event names" in errors

    assert "tool_call_only_capability_gap missing_events must be listed in missing_expected_events" in errors
  end

  test "rejects failure reports without a tool-call capability-gap diagnostic" do
    report = Map.put(valid_failure_report(), "diagnostics", [])

    assert {:error, errors} = AgentProbeReport.validate_failure(report)

    assert "failure report must include a tool_call_only_capability_gap diagnostic with missing_events and observed_events" in errors
  end

  test "rejects failure reports without unsupported capability declarations" do
    report = Map.delete(valid_failure_report(), "unsupported_client_capabilities")

    assert {:error, errors} = AgentProbeReport.validate_failure(report)

    assert "unsupported_client_capabilities must declare unsupported mediated capability families" in errors
  end

  test "rejects failure reports when unsupported capability families are incomplete" do
    report =
      valid_failure_report()
      |> Map.put("expected_events", [
        "agent_initialized",
        "file_read_requested",
        "terminal_create_requested",
        "turn_finished"
      ])
      |> Map.put("missing_expected_events", ["file_read_requested", "terminal_create_requested"])
      |> update_in(["diagnostics"], fn [diagnostic] ->
        [
          Map.put(diagnostic, "missing_events", [
            "file_read_requested",
            "terminal_create_requested"
          ])
        ]
      end)

    assert {:error, errors} = AgentProbeReport.validate_failure(report)

    assert "unsupported_client_capabilities must declare missing capability families: terminal" in errors
  end

  test "rejects failure reports whose diagnostic observed events are not in events" do
    report =
      valid_failure_report()
      |> update_in(["diagnostics"], fn [diagnostic] ->
        [Map.put(diagnostic, "observed_events", ["tool_call", "terminal_session_update"])]
      end)

    assert {:error, errors} = AgentProbeReport.validate_failure(report)

    assert "tool_call_only_capability_gap observed_events must be present in events" in errors
  end

  test "validates failure report files" do
    path =
      Path.join(System.tmp_dir!(), "haven-valid-probe-failure-#{System.unique_integer()}.json")

    File.write!(path, Jason.encode!(valid_failure_report()))

    assert :ok = AgentProbeReport.validate_failure_file(path)

    File.rm(path)
  end

  test "accepts load reports with multiple real child reports" do
    assert :ok = AgentProbeReport.validate_load(valid_load_report())
  end

  test "rejects load reports with duplicate child run ids" do
    report =
      update_in(valid_load_report(), ["reports"], fn [first, second] ->
        [first, Map.put(second, "run_id", first["run_id"])]
      end)

    assert {:error, errors} = AgentProbeReport.validate_load(report)
    assert "load child reports must have distinct run_ids: run-1" in errors
  end

  test "rejects load reports with non-real child reports" do
    report =
      update_in(valid_load_report(), ["reports"], fn [first, second] ->
        [
          first,
          put_in(second, ["real_agent_evidence"], %{"required" => true, "accepted" => false})
        ]
      end)

    assert {:error, errors} = AgentProbeReport.validate_load(report)

    assert "all load child reports must have required=true and accepted=true real_agent_evidence" in errors

    assert "child report 2: real_agent_evidence must have required=true and accepted=true" in errors
  end

  test "validates load report files" do
    path = Path.join(System.tmp_dir!(), "haven-valid-probe-load-#{System.unique_integer()}.json")

    File.write!(path, Jason.encode!(valid_load_report()))

    assert :ok = AgentProbeReport.validate_load_file(path)

    File.rm(path)
  end

  defp valid_report do
    %{
      "run_id" => "run-1",
      "agent" => "real-agent",
      "workspace" => "/workspace",
      "status" => "idle",
      "prompt" => "summarize",
      "expected_events" => ["agent_initialized", "turn_finished"],
      "missing_expected_events" => [],
      "real_agent_evidence" => %{"required" => true, "accepted" => true},
      "redactions" => [],
      "events" => [
        %{
          "seq" => 1,
          "type" => "run_created",
          "payload" => %{"agent" => "real-agent", "workspace" => "/workspace"}
        },
        %{"seq" => 2, "type" => "agent_process_started", "payload" => %{}},
        %{"seq" => 3, "type" => "agent_initialized", "payload" => %{}},
        %{"seq" => 4, "type" => "agent_session_started", "payload" => %{}},
        %{"seq" => 5, "type" => "turn_started", "payload" => %{}},
        %{"seq" => 6, "type" => "user_message", "payload" => %{"text" => "summarize"}},
        %{"seq" => 7, "type" => "turn_finished", "payload" => %{"stopReason" => "end_turn"}}
      ]
    }
  end

  defp valid_failure_report do
    %{
      "run_id" => "run-2",
      "agent" => "real-agent",
      "workspace" => "/workspace",
      "status" => "idle",
      "prompt" => "read README.md",
      "expected_events" => [
        "agent_initialized",
        "file_read_requested",
        "file_read_succeeded",
        "turn_finished"
      ],
      "missing_expected_events" => ["file_read_requested", "file_read_succeeded"],
      "expected_event_fields" => [
        %{"event" => "file_read_requested", "field" => "path", "value" => "README.md"},
        %{"event" => "file_read_succeeded", "field" => "path", "value" => "README.md"}
      ],
      "missing_expected_event_fields" => [],
      "real_agent_evidence" => %{"required" => true, "accepted" => true},
      "redactions" => [],
      "diagnostics" => [
        %{
          "type" => "tool_call_only_capability_gap",
          "message" => "Generic ACP tool calls were observed instead.",
          "missing_events" => ["file_read_requested", "file_read_succeeded"],
          "observed_events" => ["tool_call", "tool_call_update"]
        }
      ],
      "unsupported_client_capabilities" => [
        %{
          "capability" => "fs/read_text_file",
          "reason" =>
            "Observed generic ACP tool_call activity instead of Haven-mediated client capability events.",
          "missing_events" => ["file_read_requested", "file_read_succeeded"],
          "observed_events" => ["tool_call", "tool_call_update"]
        }
      ],
      "events" => [
        %{
          "seq" => 1,
          "type" => "run_created",
          "payload" => %{"agent" => "real-agent", "workspace" => "/workspace"}
        },
        %{"seq" => 2, "type" => "agent_process_started", "payload" => %{}},
        %{"seq" => 3, "type" => "agent_initialized", "payload" => %{}},
        %{"seq" => 4, "type" => "agent_session_started", "payload" => %{}},
        %{"seq" => 5, "type" => "turn_started", "payload" => %{}},
        %{"seq" => 6, "type" => "user_message", "payload" => %{"text" => "read README.md"}},
        %{"seq" => 7, "type" => "tool_call", "payload" => %{"title" => "Read"}},
        %{"seq" => 8, "type" => "tool_call_update", "payload" => %{"status" => "completed"}},
        %{"seq" => 9, "type" => "turn_finished", "payload" => %{"stopReason" => "end_turn"}}
      ]
    }
  end

  defp valid_load_report do
    second =
      valid_report()
      |> Map.put("run_id", "run-2")
      |> update_event("run_created", fn event ->
        put_in(event, ["payload", "workspace"], "/workspace")
      end)

    %{
      "kind" => "agent_probe_load",
      "agent" => "real-agent",
      "workspace" => "/workspace",
      "prompt" => "summarize",
      "run_count" => 2,
      "status" => "passed",
      "expected_events" => ["agent_initialized", "turn_finished"],
      "expected_event_fields" => [],
      "failures" => [],
      "reports" => [valid_report(), second]
    }
  end

  defp update_event(report, type, fun) do
    Map.update!(report, "events", fn events ->
      Enum.map(events, fn
        %{"type" => ^type} = event -> fun.(event)
        event -> event
      end)
    end)
  end
end
