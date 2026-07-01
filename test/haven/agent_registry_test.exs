defmodule Haven.AgentRegistryTest do
  use ExUnit.Case, async: true

  alias Haven.AgentRegistry

  test "turns npx registry entries into Haven command suggestions" do
    registry = %{
      "agents" => [
        %{
          "id" => "codex-acp",
          "name" => "Codex",
          "version" => "1.0.1",
          "description" => "ACP adapter",
          "distribution" => %{
            "npx" => %{
              "package" => "@agentclientprotocol/codex-acp@1.0.1",
              "args" => ["--flag"],
              "env" => %{"CODEX_HOME" => "{workspace}/.codex"}
            }
          }
        },
        %{
          "id" => "binary-only",
          "distribution" => %{
            "binary" => %{
              "darwin-aarch64" => %{"cmd" => "./agent"}
            }
          }
        }
      ]
    }

    assert AgentRegistry.suggestions(registry) == [
             %{
               id: "codex-acp",
               name: "Codex",
               version: "1.0.1",
               description: "ACP adapter",
               executable: "npx",
               args: ["-y", "@agentclientprotocol/codex-acp@1.0.1", "--flag"],
               env: %{"CODEX_HOME" => "{workspace}/.codex"},
               package: "@agentclientprotocol/codex-acp@1.0.1"
             }
           ]
  end

  test "ignores malformed registry payloads" do
    assert AgentRegistry.suggestions(%{}) == []

    assert AgentRegistry.suggestions(%{
             "agents" => [
               %{"id" => "missing-package", "distribution" => %{"npx" => %{}}},
               %{"id" => "bad-package", "distribution" => %{"npx" => %{"package" => ""}}}
             ]
           }) == []
  end

  test "builds a preflight and proof-command trial command for registry suggestions" do
    suggestion = %{
      id: "codex-acp",
      name: "Codex",
      version: "1.0.1",
      description: "ACP adapter",
      executable: "npx",
      args: ["-y", "@agentclientprotocol/codex-acp@1.0.1"],
      env: %{"CODEX_HOME" => "{workspace}/.codex"},
      package: "@agentclientprotocol/codex-acp@1.0.1"
    }

    command = AgentRegistry.trial_command(suggestion, "/tmp/workspace with space")

    assert command =~ "HAVEN_AGENTS_JSON="
    assert command =~ "mix haven.agent_probe --list-agents --preflight --proof-commands"
    assert command =~ "--workspace '/tmp/workspace with space'"
    assert command =~ ~s|"codex-acp"|
    assert command =~ ~s|"executable":"npx"|
    assert command =~ ~s|"args":["-y","@agentclientprotocol/codex-acp@1.0.1"]|
    assert command =~ ~s|"env":{"CODEX_HOME":"{workspace}/.codex"}|
  end
end
