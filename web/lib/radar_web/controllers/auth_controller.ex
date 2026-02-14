defmodule RadarWeb.AuthController do
  use RadarWeb, :controller

  plug Ueberauth

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    email = auth.info.email
    name = auth.info.name

    if email in Application.get_env(:radar, :admin_emails, []) do
      conn
      |> put_session(:admin_email, email)
      |> put_session(:admin_name, name)
      |> redirect(to: ~p"/admin")
    else
      conn
      |> put_flash(:error, "#{email} is not authorized to access the admin panel.")
      |> redirect(to: ~p"/")
    end
  end

  def callback(%{assigns: %{ueberauth_failure: _failure}} = conn, _params) do
    conn
    |> put_flash(:error, "Authentication failed. Please try again.")
    |> redirect(to: ~p"/")
  end

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/")
  end
end
