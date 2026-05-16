defmodule RadarWeb.AdminComponents do
  @moduledoc false

  use RadarWeb, :html

  attr :active, :string, required: true
  attr :current_admin, :map, required: true
  attr :infraction_count, :integer, required: true

  slot :inner_block, required: true

  def admin_shell(assigns) do
    ~H"""
    <div class="max-w-6xl mx-auto p-6 space-y-6">
      <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 class="text-3xl font-bold">Admin</h1>
          <div class="tabs tabs-box mt-4">
            <.link navigate={~p"/admin"} class={tab_class(@active, "config")}>
              Radar Configuration
            </.link>
            <.link navigate={~p"/admin/infractions"} class={tab_class(@active, "infractions")}>
              Infractions <span class="badge badge-sm ml-2">{@infraction_count}</span>
            </.link>
          </div>
        </div>
        <div class="flex items-center gap-3">
          <span class="text-sm opacity-70">{@current_admin.email}</span>
          <.link href={~p"/auth/logout"} method="delete" class="btn btn-sm btn-outline">
            Sign out
          </.link>
        </div>
      </div>

      {render_slot(@inner_block)}
    </div>
    """
  end

  defp tab_class(active_tab, tab) do
    ["tab", active_tab == tab && "tab-active"]
  end
end
