defmodule Haven.AgentsTest do
  use ExUnit.Case, async: false

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
    Application.put_env(:haven, :agents, %{
      "external" => %{
        executable: "/bin/agent",
        args: ["--workspace", "{workspace}"],
        env: %{"WORKSPACE" => "{workspace}", "MODE" => "smoke"}
      }
    })

    assert {:ok, command} = Agents.command("external", "/repo")
    assert command.label == "external"
    assert command.executable == "/bin/agent"
    assert command.args == ["--workspace", "/repo"]
    assert command.env == [{"MODE", "smoke"}, {"WORKSPACE", "/repo"}]
  end

  test "rejects invalid configured agent env" do
    Application.put_env(:haven, :agents, %{
      "external" => %{executable: "/bin/agent", env: [{"TOKEN", 123}]}
    })

    assert {:error, {:invalid_agent_field, :env}} = Agents.command("external", "/repo")
  end

  test "lists the built-in stub and configured agent keys for run creation" do
    Application.put_env(:haven, :agents, %{
      "zeta" => %{executable: "/bin/zeta"},
      "alpha" => %{executable: "/bin/alpha"},
      "stub-acp" => %{executable: "/bin/ignored"}
    })

    assert Agents.available() == [
             {"stub-acp", "stub-acp"},
             {"alpha", "alpha"},
             {"zeta", "zeta"}
           ]
  end

  test "unknown agents are explicit errors" do
    assert {:error, {:unknown_agent, "missing"}} = Agents.command("missing", "/repo")
  end
end
