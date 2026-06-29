defmodule HavenWeb.PageControllerTest do
  use HavenWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    response = html_response(conn, 200)
    assert response =~ "Agent attention inbox"
    assert response =~ "No quiet runs yet"
  end
end
