defmodule RadarWeb.PageControllerTest do
  use RadarWeb.ConnCase

  test "GET / redirects unauthenticated visitors to admin auth", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/auth/google"
  end

  test "GET / renders the radar page for admins", %{conn: conn} do
    conn =
      conn
      |> log_in_admin()
      |> get(~p"/")

    assert html_response(conn, 200) =~ "RADAR SYSTEM ACTIVE"
  end

  defp log_in_admin(conn) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:admin_email, "admin@test.com")
    |> Plug.Conn.put_session(:admin_name, "Admin")
  end
end
