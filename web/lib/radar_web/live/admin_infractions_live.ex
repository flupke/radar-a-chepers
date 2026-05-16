defmodule RadarWeb.AdminInfractionsLive do
  use RadarWeb, :live_view

  import RadarWeb.AdminComponents

  alias Radar.{Infractions, Photos}

  @infractions_per_page 100

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Radar.PubSub, "infractions")
    end

    {:ok,
     socket
     |> assign(:infractions_per_page, @infractions_per_page)
     |> assign_infraction_data(1, :date, :desc)}
  end

  def handle_params(params, _uri, socket) do
    {:noreply,
     assign_infraction_data(
       socket,
       parse_page(params["page"]),
       parse_sort_by(params["sort"]),
       parse_sort_dir(params["dir"])
     )}
  end

  def render(assigns) do
    ~H"""
    <.admin_shell
      active="infractions"
      current_admin={@current_admin}
      infraction_count={@infraction_count}
    >
      <div class="space-y-4">
        <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <div>
            <h2 class="text-xl font-semibold">Infractions</h2>
            <p class="text-sm opacity-70">
              {infraction_page_summary(@infraction_count, @infraction_page)}
            </p>
          </div>
          <div :if={@infraction_rows != []} class="join">
            <.link
              id="download-all-photos"
              href={
                ~p"/admin/infractions/photos.zip?#{page_params(@infraction_page, @sort_by, @sort_dir)}"
              }
              download={"infraction-photos-page-#{@infraction_page}.zip"}
              class="btn btn-primary join-item"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> Download page photos
            </.link>
            <div class="dropdown dropdown-end">
              <button
                type="button"
                tabindex="0"
                class="btn btn-primary join-item px-3"
                aria-label="Download options"
              >
                <.icon name="hero-chevron-down" class="size-4" />
              </button>
              <ul
                tabindex="0"
                class="dropdown-content menu bg-base-100 rounded-box z-10 mt-2 w-56 border border-base-300 p-2 shadow"
              >
                <li>
                  <.link
                    href={~p"/admin/infractions/photos.zip?#{all_photos_params(@sort_by, @sort_dir)}"}
                    download="infraction-photos-all.zip"
                  >
                    Download all photos
                  </.link>
                </li>
              </ul>
            </div>
          </div>
          <button
            :if={@infraction_rows == []}
            id="download-all-photos"
            type="button"
            class="btn btn-primary"
            disabled
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Download page photos
          </button>
        </div>

        <div
          :if={@infraction_rows == []}
          class="rounded-lg border border-base-300 bg-base-200 p-8 text-center"
        >
          <p class="font-medium">No infractions yet.</p>
        </div>

        <div
          :if={@infraction_rows != []}
          class="overflow-x-auto rounded-lg border border-base-300 bg-base-100"
        >
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Photo</th>
                <th>Case</th>
                <th>
                  <.link
                    patch={~p"/admin/infractions?#{sort_params(@sort_by, @sort_dir, :date)}"}
                    class="inline-flex items-center gap-1 link link-hover"
                  >
                    Date
                    <.icon
                      :if={@sort_by == :date}
                      name={sort_icon(@sort_dir)}
                      class="size-3"
                    />
                  </.link>
                </th>
                <th>
                  <.link
                    patch={~p"/admin/infractions?#{sort_params(@sort_by, @sort_dir, :location)}"}
                    class="inline-flex items-center gap-1 link link-hover"
                  >
                    Location
                    <.icon
                      :if={@sort_by == :location}
                      name={sort_icon(@sort_dir)}
                      class="size-3"
                    />
                  </.link>
                </th>
                <th>
                  <.link
                    patch={~p"/admin/infractions?#{sort_params(@sort_by, @sort_dir, :speed)}"}
                    class="inline-flex items-center gap-1 link link-hover"
                  >
                    Speed
                    <.icon
                      :if={@sort_by == :speed}
                      name={sort_icon(@sort_dir)}
                      class="size-3"
                    />
                  </.link>
                </th>
                <th>File</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @infraction_rows} id={"infraction-#{row.id}"}>
                <td>
                  <img
                    src={row.photo_url}
                    alt={"Capture for infraction #{row.short_id}"}
                    class="size-16 min-w-16 rounded object-cover"
                  />
                </td>
                <td class="min-w-36">
                  <.link
                    href={~p"/infractions/#{row.id}"}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="font-mono font-semibold link link-hover"
                  >
                    #{row.short_id}
                  </.link>
                  <div class="badge badge-outline badge-sm mt-1 uppercase">{row.type}</div>
                </td>
                <td class="min-w-44">{row.datetime}</td>
                <td class="min-w-56">{row.location}</td>
                <td class="min-w-32">
                  <div class="font-semibold text-error">{row.recorded_speed} km/h</div>
                  <div class="text-xs opacity-70">
                    limit {row.authorized_speed} km/h, +{row.speed_delta}
                  </div>
                </td>
                <td class="min-w-44">
                  <div class="font-mono text-xs break-all">{row.filename}</div>
                  <div class="text-xs opacity-60">{row.file_size}</div>
                </td>
                <td class="text-right">
                  <a
                    href={row.download_url}
                    download={row.filename}
                    class="btn btn-ghost btn-xs"
                    aria-label={"Download #{row.filename}"}
                  >
                    <.icon name="hero-arrow-down-tray" class="size-4" />
                    <span class="hidden sm:inline">Download</span>
                  </a>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div
          :if={@infraction_count > @infractions_per_page}
          class="flex items-center justify-end gap-2"
        >
          <.link
            :if={@infraction_page > 1}
            patch={~p"/admin/infractions?#{page_params(@infraction_page - 1, @sort_by, @sort_dir)}"}
            class="btn btn-sm btn-outline"
          >
            Previous
          </.link>
          <button :if={@infraction_page == 1} type="button" class="btn btn-sm btn-outline" disabled>
            Previous
          </button>
          <span class="px-3 text-sm opacity-70">
            Page {@infraction_page} of {@total_infraction_pages}
          </span>
          <.link
            :if={@infraction_page < @total_infraction_pages}
            patch={~p"/admin/infractions?#{page_params(@infraction_page + 1, @sort_by, @sort_dir)}"}
            class="btn btn-sm btn-outline"
          >
            Next
          </.link>
          <button
            :if={@infraction_page == @total_infraction_pages}
            type="button"
            class="btn btn-sm btn-outline"
            disabled
          >
            Next
          </button>
        </div>
      </div>
    </.admin_shell>
    """
  end

  def handle_info({:new_infraction, _infraction}, socket) do
    {:noreply,
     assign_infraction_data(
       socket,
       socket.assigns.infraction_page,
       socket.assigns.sort_by,
       socket.assigns.sort_dir
     )}
  end

  defp assign_infraction_data(socket, page, sort_by, sort_dir) do
    infraction_count = Infractions.count_infractions()
    total_pages = total_infraction_pages(infraction_count)
    page = min(page, total_pages)

    socket
    |> assign(:infraction_count, infraction_count)
    |> assign(:infraction_page, page)
    |> assign(:total_infraction_pages, total_pages)
    |> assign(:sort_by, sort_by)
    |> assign(:sort_dir, sort_dir)
    |> assign(:infraction_rows, list_infraction_rows(page, sort_by, sort_dir))
  end

  defp list_infraction_rows(page, sort_by, sort_dir) do
    Infractions.list_infractions(
      limit: @infractions_per_page,
      offset: (page - 1) * @infractions_per_page,
      sort_by: sort_by,
      sort_dir: sort_dir
    )
    |> Enum.map(&infraction_row/1)
  end

  defp infraction_row(infraction) do
    %{
      id: infraction.id,
      short_id: short_id(infraction.id),
      type: String.replace(infraction.type, "_", " "),
      datetime: format_table_datetime(infraction.datetime_taken),
      recorded_speed: infraction.recorded_speed,
      authorized_speed: infraction.authorized_speed,
      speed_delta: infraction.recorded_speed - infraction.authorized_speed,
      location: infraction.location,
      filename: infraction.photo.filename,
      file_size: format_file_size(infraction.photo.file_size),
      photo_url: Photos.get_photo_url!(infraction.photo),
      download_url: Photos.get_photo_url!(infraction.photo, download: true)
    }
  end

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {page, _rest} when page > 0 -> page
      _ -> 1
    end
  end

  defp parse_page(_page), do: 1

  defp parse_sort_by(sort_by) when sort_by in ["date", "speed", "location"] do
    String.to_existing_atom(sort_by)
  end

  defp parse_sort_by(_sort_by), do: :date

  defp parse_sort_dir(sort_dir) when sort_dir in ["asc", "desc"] do
    String.to_existing_atom(sort_dir)
  end

  defp parse_sort_dir(_sort_dir), do: :desc

  defp sort_params(current_sort_by, current_sort_dir, sort_by) do
    %{
      page: 1,
      sort: sort_by,
      dir: next_sort_dir(current_sort_by, current_sort_dir, sort_by)
    }
  end

  defp next_sort_dir(sort_by, :asc, sort_by), do: :desc
  defp next_sort_dir(sort_by, :desc, sort_by), do: :asc
  defp next_sort_dir(_current_sort_by, _current_sort_dir, :location), do: :asc
  defp next_sort_dir(_current_sort_by, _current_sort_dir, _sort_by), do: :desc

  defp page_params(page, sort_by, sort_dir) do
    %{page: page, sort: sort_by, dir: sort_dir}
  end

  defp all_photos_params(sort_by, sort_dir) do
    %{scope: "all", sort: sort_by, dir: sort_dir}
  end

  defp sort_icon(:asc), do: "hero-chevron-up"
  defp sort_icon(:desc), do: "hero-chevron-down"

  defp total_infraction_pages(0), do: 1

  defp total_infraction_pages(count) do
    ceil(count / @infractions_per_page)
  end

  defp infraction_page_summary(0, _page), do: "0 infractions"

  defp infraction_page_summary(count, page) do
    first = (page - 1) * @infractions_per_page + 1
    last = min(page * @infractions_per_page, count)

    "Showing #{first}-#{last} of #{pluralize_infraction(count)}"
  end

  defp short_id(id) do
    id
    |> to_string()
    |> String.slice(0, 8)
  end

  defp format_table_datetime(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y %H:%M")
  end

  defp format_file_size(nil), do: "Unknown size"

  defp format_file_size(bytes) when bytes < 1024, do: "#{bytes} B"

  defp format_file_size(bytes) when bytes < 1024 * 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_file_size(bytes) do
    "#{Float.round(bytes / 1024 / 1024, 1)} MB"
  end

  defp pluralize_infraction(1), do: "1 infraction"
  defp pluralize_infraction(count), do: "#{count} infractions"
end
