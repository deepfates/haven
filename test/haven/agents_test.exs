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
    assert command.executable =~ "mix"
    assert command.cwd == nil
    assert command.env == []

    assert command.args == [
             "run",
             "--no-compile",
             "--no-start",
             "priv/agent_stub.exs",
             "/tmp/work"
           ]
  end

  test "resolves configured agents and substitutes workspace" do
    executable = System.find_executable("sh")

    Application.put_env(:haven, :agents, %{
      "external" => %{
        executable: "sh",
        args: ["--workspace", "{workspace}"],
        cwd: "{workspace}",
        env: %{"WORKSPACE" => "{workspace}", "MODE" => "smoke"}
      }
    })

    assert {:ok, command} = Agents.command("external", "/repo")
    assert command.label == "external"
    assert command.executable == executable
    assert command.args == ["--workspace", "/repo"]
    assert command.cwd == "/repo"
    assert command.env == [{"MODE", "smoke"}, {"WORKSPACE", "/repo"}]
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

  test "rejects invalid configured agent env" do
    Application.put_env(:haven, :agents, %{
      "external" => %{executable: "sh", env: [{"TOKEN", 123}]}
    })

    assert {:error, {:invalid_agent_field, :env}} = Agents.command("external", "/repo")
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

  test "resolves persisted agent configs" do
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

    assert {:ok, command} = Agents.command("persisted", "/repo")
    assert command.label == "persisted"
    assert command.executable == executable
    assert command.args == ["-c", "echo /repo"]
    assert command.cwd == "/repo"
    assert command.env == [{"WORKSPACE", "/repo"}]
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

  test "unknown agents are explicit errors" do
    assert {:error, {:unknown_agent, "missing"}} = Agents.command("missing", "/repo")
  end
end
