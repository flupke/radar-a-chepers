defmodule RadarWeb.AuthController do
  use RadarWeb, :controller

  plug Ueberauth

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    email = auth.info.email
    name = auth.info.name

    if email in Application.get_env(:radar, :admin_emails, []) do
      return_to = get_session(conn, :admin_return_to)

      conn
      |> put_session(:admin_email, email)
      |> put_session(:admin_name, name)
      |> delete_session(:admin_return_to)
      |> redirect(to: verified_return_to(return_to))
    else
      conn
      |> delete_session(:admin_return_to)
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

  defp verified_return_to(return_to) when is_binary(return_to) do
    uri = URI.parse(return_to)

    if uri.scheme == nil and uri.host == nil and String.starts_with?(return_to, "/") and
         not String.starts_with?(return_to, "//") do
      return_to
    else
      ~p"/admin"
    end
  end

  defp verified_return_to(_return_to), do: ~p"/admin"
end
