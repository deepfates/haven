defmodule Haven.AgentsTest do
  use Haven.DataCase, async: false

  alias Haven.Agents

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

  test "resolves the built-in stub ACP agent" do
    assert {:ok, command} = Agents.command("stub-acp", "/tmp/work")
    assert command.label == "stub-acp"
    assert command.executable =~ "elixir"
    assert command.cwd == nil
    assert command.env == []
    assert ["-pa", _path | _rest] = command.args
    assert Enum.slice(command.args, -2, 2) == ["priv/agent_stub.exs", "/tmp/work"]
  end

  @tag :tmp_dir
  test "resolves configured agents and substitutes workspace", %{tmp_dir: tmp_dir} do
    executable = System.find_executable("sh")

    Application.put_env(:haven, :agents, %{
      "external" => %{
        executable: "sh",
        args: ["--workspace", "{workspace}"],
        cwd: "{workspace}",
        env: %{"WORKSPACE" => "{workspace}", "MODE" => "smoke"}
      }
    })

    assert {:ok, command} = Agents.command("external", tmp_dir)
    assert command.label == "external"
    assert command.executable == executable
    assert command.args == ["--workspace", tmp_dir]
    assert command.cwd == tmp_dir
    assert command.env == [{"MODE", "smoke"}, {"WORKSPACE", tmp_dir}]
  end

  test "resolves configured absolute executable paths" do
    executable = System.find_executable("sh")

    Application.put_env(:haven, :agents, %{
      "external" => %{executable: executable}
    })

    assert {:ok, command} = Agents.command("external", "/repo")
    assert command.executable == executable
  end

  test "rejects configured agents with missing executables" do
    Application.put_env(:haven, :agents, %{
      "external" => %{executable: "haven-definitely-missing-agent"}
    })

    assert {:error, {:missing_executable, "haven-definitely-missing-agent"}} =
             Agents.command("external", "/repo")
  end

  test "rejects invalid configured agent cwd" do
    Application.put_env(:haven, :agents, %{
      "external" => %{executable: "sh", cwd: 123}
    })

    assert {:error, {:invalid_agent_field, :cwd}} = Agents.command("external", "/repo")
  end

  test "rejects configured agents with missing cwd" do
    missing_cwd = Path.join(System.tmp_dir!(), "haven-missing-agent-cwd")
    File.rm_rf!(missing_cwd)

    Application.put_env(:haven, :agents, %{
      "external" => %{executable: "sh", cwd: missing_cwd}
    })

    assert {:error, {:missing_cwd, ^missing_cwd}} = Agents.command("external", "/repo")
  end

  test "rejects invalid configured agent env" do
    Application.put_env(:haven, :agents, %{
      "external" => %{executable: "sh", env: [{"TOKEN", 123}]}
    })

    assert {:error, {:invalid_agent_field, :env}} = Agents.command("external", "/repo")

    Application.put_env(:haven, :agents, %{
      "external" => %{executable: "sh", env: %{"BAD=KEY" => "value"}}
    })

    assert {:error, {:invalid_agent_field, :env}} = Agents.command("external", "/repo")
  end

  test "rejects persisted agent configs with unsafe env names" do
    assert {:error, changeset} =
             Agents.create_agent_config(%{
               key: "bad-env-agent",
               executable: "sh",
               env: %{"1TOKEN" => "value"}
             })

    assert {"must contain process-safe string keys and values", _} = changeset.errors[:env]
  end

  test "lists the built-in stub and configured agent keys for run creation" do
    Application.put_env(:haven, :agents, %{
      "zeta" => %{executable: "zeta"},
      "alpha" => %{executable: "alpha"},
      "stub-acp" => %{executable: "ignored"}
    })

    assert Agents.available() == [
             {"stub-acp", "stub-acp"},
             {"alpha", "alpha"},
             {"zeta", "zeta"}
           ]
  end

  @tag :tmp_dir
  test "resolves persisted agent configs", %{tmp_dir: tmp_dir} do
    executable = System.find_executable("sh")

    assert {:ok, _agent_config} =
             Agents.create_agent_config(%{
               key: "persisted",
               executable: "sh",
               args: ["-c", "echo {workspace}"],
               cwd: "{workspace}",
               env: %{"WORKSPACE" => "{workspace}"}
             })

    assert Agents.available() == [{"stub-acp", "stub-acp"}, {"persisted", "persisted"}]

    assert {:ok, command} = Agents.command("persisted", tmp_dir)
    assert command.label == "persisted"
    assert command.executable == executable
    assert command.args == ["-c", "echo #{tmp_dir}"]
    assert command.cwd == tmp_dir
    assert command.env == [{"WORKSPACE", tmp_dir}]
  end

  test "runtime env configured agents override persisted configs with the same key" do
    assert {:ok, _agent_config} =
             Agents.create_agent_config(%{
               key: "shared",
               executable: "sh",
               args: ["persisted"]
             })

    Application.put_env(:haven, :agents, %{
      "shared" => %{executable: "sh", args: ["runtime"]}
    })

    assert {:ok, command} = Agents.command("shared", "/repo")
    assert command.args == ["runtime"]
  end

  test "updates persisted agent configs" do
    assert {:ok, agent_config} =
             Agents.create_agent_config(%{
               key: "before",
               executable: "sh",
               args: ["before"]
             })

    assert {:ok, agent_config} =
             Agents.update_agent_config(agent_config, %{
               key: "after",
               executable: "sh",
               args: ["after", "{workspace}"],
               env: %{"WORKSPACE" => "{workspace}"}
             })

    assert agent_config.key == "after"
    assert Agents.available() == [{"stub-acp", "stub-acp"}, {"after", "after"}]

    assert {:error, {:unknown_agent, "before"}} = Agents.command("before", "/repo")
    assert {:ok, command} = Agents.command("after", "/repo")
    assert command.args == ["after", "/repo"]
    assert command.env == [{"WORKSPACE", "/repo"}]
  end

  test "upserts persisted agent configs from registry suggestions" do
    suggestion = %{
      id: "codex-acp",
      executable: "npx",
      args: ["-y", "@agentclientprotocol/codex-acp@1.0.1"],
      env: %{"CODEX_HOME" => "{workspace}/.codex"},
      package: "@agentclientprotocol/codex-acp@1.0.1",
      name: "Codex",
      version: "1.0.1",
      description: "ACP adapter"
    }

    assert {:ok, agent_config} = Agents.upsert_agent_config_from_registry_suggestion(suggestion)
    assert agent_config.key == "codex-acp"
    assert agent_config.executable == "npx"
    assert agent_config.args == %{"items" => ["-y", "@agentclientprotocol/codex-acp@1.0.1"]}
    assert agent_config.cwd == "{workspace}"
    assert agent_config.env == %{"CODEX_HOME" => "{workspace}/.codex"}

    updated = %{suggestion | args: ["-y", "@agentclientprotocol/codex-acp@1.0.2"]}
    assert {:ok, updated_config} = Agents.upsert_agent_config_from_registry_suggestion(updated)
    assert updated_config.id == agent_config.id
    assert updated_config.args == %{"items" => ["-y", "@agentclientprotocol/codex-acp@1.0.2"]}
  end

  @tag :tmp_dir
  test "summarizes accepted probe reports by configured agent", %{tmp_dir: tmp_dir} do
    write_probe_report!(tmp_dir, "codex-basic.json", valid_probe_report("codex-acp"))
    write_probe_report!(tmp_dir, "other-basic.json", valid_probe_report("other-acp"))
    write_probe_report!(tmp_dir, "invalid.json", %{"agent" => "codex-acp"})

    reports_by_agent =
      Agents.accepted_probe_reports_by_agent(["codex-acp"], path: Path.join(tmp_dir, "*.json"))

    assert %{agent: "codex-acp", path: path, expected_events: expected_events} =
             reports_by_agent["codex-acp"] |> List.first()

    assert Path.basename(path) == "codex-basic.json"
    assert expected_events == ["agent_initialized", "agent_session_started", "turn_finished"]
    refute Map.has_key?(reports_by_agent, "other-acp")
  end

  @tag :tmp_dir
  test "lists accepted probe reports for one agent", %{tmp_dir: tmp_dir} do
    write_probe_report!(tmp_dir, "codex-basic.json", valid_probe_report("codex-acp"))

    assert [%{agent: "codex-acp", status: "idle", run_id: "run-codex-acp"}] =
             Agents.accepted_probe_reports("codex-acp", path: Path.join(tmp_dir, "*.json"))
  end

  @tag :tmp_dir
  test "summarizes capability gap reports by configured agent", %{tmp_dir: tmp_dir} do
    write_probe_report!(tmp_dir, "codex-gap.json", capability_gap_report("codex-acp"))

    write_probe_report!(
      tmp_dir,
      "malformed-gap.json",
      malformed_capability_gap_report("codex-acp")
    )

    write_probe_report!(tmp_dir, "other-gap.json", capability_gap_report("other-acp"))
    write_probe_report!(tmp_dir, "positive.json", valid_probe_report("codex-acp"))

    reports_by_agent =
      Agents.capability_gap_reports_by_agent(["codex-acp"], path: Path.join(tmp_dir, "*.json"))

    assert %{
             agent: "codex-acp",
             path: path,
             missing_expected_events: ["file_read_requested", "file_read_succeeded"],
             unsupported_client_capabilities: [
               %{
                 "capability" => "fs/read_text_file",
                 "missing_events" => ["file_read_requested", "file_read_succeeded"]
               }
             ]
           } = reports_by_agent["codex-acp"] |> List.first()

    assert Path.basename(path) == "codex-gap.json"
    refute Map.has_key?(reports_by_agent, "other-acp")

    refute Enum.any?(reports_by_agent["codex-acp"], fn report ->
             Path.basename(report.path) == "malformed-gap.json"
           end)
  end

  @tag :tmp_dir
  test "lists capability gap reports for one agent", %{tmp_dir: tmp_dir} do
    write_probe_report!(tmp_dir, "codex-gap.json", capability_gap_report("codex-acp"))

    assert [%{agent: "codex-acp", status: "idle", run_id: "gap-codex-acp"}] =
             Agents.capability_gap_reports("codex-acp", path: Path.join(tmp_dir, "*.json"))
  end

  test "deletes persisted agent configs" do
    assert {:ok, agent_config} =
             Agents.create_agent_config(%{
               key: "temporary",
               executable: "sh"
             })

    assert Agents.available() == [{"stub-acp", "stub-acp"}, {"temporary", "temporary"}]
    assert {:ok, _agent_config} = Agents.delete_agent_config(agent_config)

    assert Agents.available() == [{"stub-acp", "stub-acp"}]
    assert {:error, {:unknown_agent, "temporary"}} = Agents.command("temporary", "/repo")
  end

  test "unknown agents are explicit errors" do
    assert {:error, {:unknown_agent, "missing"}} = Agents.command("missing", "/repo")
  end

  defp write_probe_report!(tmp_dir, filename, report) do
    path = Path.join(tmp_dir, filename)
    File.write!(path, Jason.encode!(report, pretty: true))
    path
  end

  defp valid_probe_report(agent) do
    %{
      "run_id" => "run-#{agent}",
      "agent" => agent,
      "workspace" => "/tmp/workspace",
      "prompt" => "prove #{agent}",
      "status" => "idle",
      "real_agent_evidence" => %{"required" => true, "accepted" => true},
      "redactions" => [%{"source" => "literal"}],
      "expected_events" => ["agent_initialized", "agent_session_started", "turn_finished"],
      "expected_event_fields" => [],
      "missing_expected_events" => [],
      "missing_expected_event_fields" => [],
      "errors" => %{},
      "events" => [
        %{
          "seq" => 1,
          "type" => "run_created",
          "payload" => %{"agent" => agent, "workspace" => "/tmp/workspace"}
        },
        %{"seq" => 2, "type" => "agent_process_started", "payload" => %{}},
        %{"seq" => 3, "type" => "agent_initialized", "payload" => %{}},
        %{"seq" => 4, "type" => "agent_session_started", "payload" => %{}},
        %{"seq" => 5, "type" => "turn_started", "payload" => %{}},
        %{"seq" => 6, "type" => "user_message", "payload" => %{"text" => "prove #{agent}"}},
        %{"seq" => 7, "type" => "turn_finished", "payload" => %{}}
      ]
    }
  end

  defp capability_gap_report(agent) do
    agent
    |> valid_probe_report()
    |> Map.merge(%{
      "run_id" => "gap-#{agent}",
      "expected_events" => ["file_read_requested", "file_read_succeeded"],
      "expected_event_fields" => [
        %{"event" => "file_read_requested", "field" => "path", "value" => "README.md"},
        %{"event" => "file_read_succeeded", "field" => "path", "value" => "README.md"}
      ],
      "missing_expected_events" => ["file_read_requested", "file_read_succeeded"],
      "unsupported_client_capabilities" => [
        %{
          "capability" => "fs/read_text_file",
          "reason" =>
            "Observed generic ACP tool_call activity instead of Haven-mediated client capability events.",
          "missing_events" => ["file_read_requested", "file_read_succeeded"],
          "observed_events" => ["tool_call", "tool_call_update"]
        }
      ],
      "diagnostics" => [
        %{
          "type" => "tool_call_only_capability_gap",
          "message" =>
            "Expected Haven-mediated client capability events were missing, but generic ACP tool_call activity was observed.",
          "missing_events" => ["file_read_requested", "file_read_succeeded"],
          "observed_events" => ["tool_call", "tool_call_update"]
        }
      ],
      "events" => [
        %{
          "seq" => 1,
          "type" => "run_created",
          "payload" => %{"agent" => agent, "workspace" => "/tmp/workspace"}
        },
        %{"seq" => 2, "type" => "agent_process_started", "payload" => %{}},
        %{"seq" => 3, "type" => "agent_initialized", "payload" => %{}},
        %{"seq" => 4, "type" => "agent_session_started", "payload" => %{}},
        %{"seq" => 5, "type" => "turn_started", "payload" => %{}},
        %{"seq" => 6, "type" => "user_message", "payload" => %{"text" => "prove #{agent}"}},
        %{"seq" => 7, "type" => "tool_call", "payload" => %{}},
        %{"seq" => 8, "type" => "tool_call_update", "payload" => %{}},
        %{"seq" => 9, "type" => "turn_finished", "payload" => %{}}
      ]
    })
  end

  defp malformed_capability_gap_report(agent) do
    agent
    |> capability_gap_report()
    |> update_in(["diagnostics"], fn
      [%{"type" => "tool_call_only_capability_gap"} = diagnostic] ->
        [Map.delete(diagnostic, "message")]
    end)
  end
end
