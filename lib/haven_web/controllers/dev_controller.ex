defmodule HavenWeb.DevController do
  use HavenWeb, :controller

  alias Haven.Runs

  def sample(conn, %{"id" => id, "sample" => "echo"}) do
    respond(conn, Runs.send_prompt(id, "hello from LiveView"))
  end

  def sample(conn, %{"id" => id, "sample" => "permission"}) do
    respond(conn, Runs.send_prompt(id, "permission"))
  end

  def permission(conn, %{"id" => id, "request_id" => request_id, "option_id" => option_id}) do
    respond(conn, Runs.resolve_permission(id, request_id, option_id))
  end

  defp respond(conn, :ok), do: json(conn, %{ok: true})

  defp respond(conn, {:error, reason}) do
    conn
    |> put_status(:conflict)
    |> json(%{ok: false, error: inspect(reason)})
  end
end
