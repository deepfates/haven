defmodule HavenWeb.DevController do
  use HavenWeb, :controller

  alias Haven.Runs

  def sample(conn, %{"id" => id, "sample" => "echo"}) do
    :ok = Runs.send_prompt(id, "hello from LiveView")
    json(conn, %{ok: true})
  end

  def sample(conn, %{"id" => id, "sample" => "permission"}) do
    :ok = Runs.send_prompt(id, "permission")
    json(conn, %{ok: true})
  end

  def permission(conn, %{"id" => id, "request_id" => request_id, "option_id" => option_id}) do
    :ok = Runs.resolve_permission(id, request_id, option_id)
    json(conn, %{ok: true})
  end
end
