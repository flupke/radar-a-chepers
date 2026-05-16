defmodule RadarWeb.AuthControllerTest do
  use RadarWeb.ConnCase

  alias Ueberauth.Auth
  alias Ueberauth.Auth.Info

  test "protected admin routes store the source path before Google auth", %{conn: conn} do
    conn = get(conn, ~p"/admin/infractions?page=2")

    assert redirected_to(conn) == ~p"/auth/google"
    assert get_session(conn, :admin_return_to) == "/admin/infractions?page=2"
  end

  test "callback redirects admins to the stored source path", %{conn: conn} do
    conn =
      conn
      |> callback_conn("/admin/infractions?page=2")

    assert redirected_to(conn) == "/admin/infractions?page=2"
    assert get_session(conn, :admin_email) == "admin@test.com"
    assert get_session(conn, :admin_name) == "Admin"
    assert get_session(conn, :admin_return_to) == nil
  end

  test "callback falls back to admin for missing or unsafe source paths", %{conn: conn} do
    Enum.each([nil, "https://example.com/admin", "//example.com/admin"], fn return_to ->
      conn =
        conn
        |> recycle()
        |> callback_conn(return_to)

      assert redirected_to(conn) == ~p"/admin"
    end)
  end

  defp callback_conn(conn, return_to) do
    session =
      if return_to do
        %{admin_return_to: return_to}
      else
        %{}
      end

    conn
    |> init_test_session(session)
    |> assign(:ueberauth_auth, %Auth{info: %Info{email: "admin@test.com", name: "Admin"}})
    |> RadarWeb.AuthController.callback(%{})
  end
end
