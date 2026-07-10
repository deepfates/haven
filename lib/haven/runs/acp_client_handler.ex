defmodule Haven.Runs.ACPClientHandler do
  @moduledoc false

  alias Haven.Runs.RunServer

  def handle_request({:request_permission, request}, run_server) do
    RunServer.agent_permission_requested(run_server, request)
  end

  def handle_request({:read_text_file, request}, run_server) do
    RunServer.agent_read_text_file_requested(run_server, request)
  end

  def handle_request({:write_text_file, request}, run_server) do
    RunServer.agent_write_text_file_requested(run_server, request)
  end

  def handle_request(request, run_server)
      when elem(request, 0) in [
             :create_terminal,
             :terminal_output,
             :release_terminal,
             :wait_for_terminal_exit,
             :kill_terminal_command
           ] do
    RunServer.agent_terminal_requested(run_server, request)
  end

  def handle_request(_request, _run_server), do: {:error, ACP.Error.method_not_found()}

  def handle_notification(_notification, _run_server), do: :ok
end
