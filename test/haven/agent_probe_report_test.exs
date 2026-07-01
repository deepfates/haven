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

  defp update_event(report, type, fun) do
    Map.update!(report, "events", fn events ->
      Enum.map(events, fn
        %{"type" => ^type} = event -> fun.(event)
        event -> event
      end)
    end)
  end
end
