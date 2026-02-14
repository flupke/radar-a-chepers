defmodule RadarWeb.AdminAuth do
  @moduledoc false

  import Phoenix.LiveView
  import Phoenix.Component

  def on_mount(:default, _params, session, socket) do
    email = session["admin_email"]
    name = session["admin_name"]

    if email && email in Application.get_env(:radar, :admin_emails, []) do
      {:cont, assign(socket, :current_admin, %{email: email, name: name})}
    else
      {:halt, redirect(socket, to: "/auth/google")}
    end
  end
end
