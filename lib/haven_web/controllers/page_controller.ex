defmodule HavenWeb.PageController do
  use HavenWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
