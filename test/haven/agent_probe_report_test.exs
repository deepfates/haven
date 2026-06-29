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

  test "rejects structurally invalid events" do
    report = Map.put(valid_report(), "events", [%{"seq" => 2, "type" => "run_created"}])

    assert {:error, errors} = AgentProbeReport.validate(report)
    assert "event 1 must include integer seq, string type, and object payload" in errors
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
        %{"seq" => 1, "type" => "run_created", "payload" => %{}},
        %{"seq" => 2, "type" => "agent_initialized", "payload" => %{}},
        %{"seq" => 3, "type" => "turn_finished", "payload" => %{}}
      ]
    }
  end
end
