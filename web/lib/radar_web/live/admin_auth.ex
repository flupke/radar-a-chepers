defmodule RadarWeb.AdminAuth do
  @moduledoc false

  import Plug.Conn, only: [get_session: 2, halt: 1, put_session: 3]
  import Phoenix.LiveView
  import Phoenix.Component

  def init(opts), do: opts

  def call(conn, :require_authenticated_admin), do: require_authenticated_admin(conn, [])

  def on_mount(:default, _params, session, socket) do
    case admin_from_session(session) do
      nil -> {:halt, redirect(socket, to: "/auth/google")}
      admin -> {:cont, assign(socket, :current_admin, admin)}
    end
  end

  def require_authenticated_admin(conn, _opts) do
    session = %{
      "admin_email" => get_session(conn, :admin_email),
      "admin_name" => get_session(conn, :admin_name)
    }

    case admin_from_session(session) do
      nil ->
        conn
        |> put_session(:admin_return_to, Phoenix.Controller.current_path(conn))
        |> Phoenix.Controller.redirect(to: "/auth/google")
        |> halt()

      admin ->
        Plug.Conn.assign(conn, :current_admin, admin)
    end
  end

  defp admin_from_session(session) do
    email = session["admin_email"]
    name = session["admin_name"]

    if email && email in Application.get_env(:radar, :admin_emails, []) do
      %{email: email, name: name}
    end
  end
end
