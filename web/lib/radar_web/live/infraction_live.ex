defmodule RadarWeb.InfractionLive do
  use RadarWeb, :live_view

  alias Radar.Infractions

  def mount(%{"id" => id}, _session, socket) do
    try do
      infraction = Infractions.get_infraction!(id)

      {:ok,
       socket
       |> assign(:infraction, infraction)
       |> assign(
         :page_title,
         "Infraction ##{short_id(infraction.id)}"
       )}
    rescue
      Ecto.NoResultsError ->
        {:ok,
         socket
         |> put_flash(:error, "Infraction not found")
         |> redirect(to: ~p"/")}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="min-h-screen bg-base-300 text-base-content flex flex-col md:h-screen md:overflow-hidden">
        <!-- Header -->
        <div class="navbar bg-primary hidden shrink-0 flex-col items-start gap-1 px-3 py-3 sm:flex-row sm:items-center sm:px-6 md:flex">
          <div class="min-w-0 flex-1">
            <h1 class="text-lg font-bold text-primary-content sm:text-xl">
              Infraction #{short_id(@infraction.id)}
            </h1>
          </div>
          <div class="flex-none text-xs text-primary-content/70 sm:text-sm">
            {format_short_datetime(@infraction.datetime_taken)}
          </div>
        </div>
        
    <!-- Main Content -->
        <div class="flex-1 flex flex-col md:min-h-0 md:flex-row">
          <!-- Photo -->
          <div class="relative h-[100dvh] min-h-[100dvh] min-w-0 overflow-hidden bg-base-300 md:h-auto md:min-h-0 md:flex-1">
            <div
              id={"infraction-photo-scroll-#{@infraction.id}"}
              phx-hook="CenterPhotoScroller"
              class="infraction-photo-scroll h-full overflow-x-auto overflow-y-hidden md:overflow-hidden"
            >
              <img
                src={Radar.Photos.get_photo_url!(@infraction.photo)}
                alt="Speed camera capture"
                class="h-full w-auto max-w-none object-cover md:w-full md:max-w-full"
              />
            </div>
            <div class="badge badge-error badge-lg absolute top-4 right-4 hidden font-bold md:flex">
              VIOLATION
            </div>

            <div class="pointer-events-none absolute inset-0 md:hidden">
              <div class="absolute top-3 left-3 max-w-[58vw] rounded bg-neutral/80 px-3 py-2 text-xs font-semibold text-neutral-content shadow">
                {format_short_datetime(@infraction.datetime_taken)}
              </div>
              <div class="absolute top-3 right-3 rounded bg-error px-3 py-2 text-sm font-bold text-error-content shadow">
                {@infraction.recorded_speed} km/h
              </div>
              <a
                href={Radar.Photos.get_photo_url!(@infraction.photo, download: true)}
                download={@infraction.photo.filename}
                class="btn btn-primary btn-sm pointer-events-auto absolute bottom-4 right-3 shadow"
                aria-label="Download photo"
              >
                <.icon name="hero-arrow-down-tray" class="size-4" /> Download
              </a>
            </div>
          </div>
          
    <!-- Sidebar -->
          <div class="w-full bg-base-200 border-t border-base-300 flex flex-col md:w-80 md:shrink-0 md:border-l md:border-t-0 md:overflow-y-auto">
            <!-- Speed Stats -->
            <div class="stats stats-vertical w-full shadow-none rounded-none border-b border-base-300">
              <div class="stat">
                <div class="stat-title">Recorded Speed</div>
                <div class="stat-value text-error">{@infraction.recorded_speed}</div>
                <div class="stat-desc">km/h</div>
              </div>
              <div class="stat">
                <div class="stat-title">Speed Limit</div>
                <div class="stat-value">{@infraction.authorized_speed}</div>
                <div class="stat-desc">km/h</div>
              </div>
              <div class="stat">
                <div class="stat-title">Violation</div>
                <div class="stat-value text-error text-2xl">
                  +{@infraction.recorded_speed - @infraction.authorized_speed} km/h
                </div>
                <div class={"stat-desc font-semibold #{severity_color(violation_severity(@infraction.recorded_speed, @infraction.authorized_speed))}"}>
                  {violation_severity(@infraction.recorded_speed, @infraction.authorized_speed)}
                </div>
              </div>
            </div>
            
    <!-- Case Info -->
            <div class="p-5 border-b border-base-300 space-y-3 text-sm">
              <div class="flex justify-between gap-4">
                <span class="shrink-0 opacity-60">Case ID</span>
                <span class="min-w-0 max-w-[70%] break-all text-right font-mono">
                  #{to_string(@infraction.id)}
                </span>
              </div>
              <div class="flex justify-between gap-4">
                <span class="shrink-0 opacity-60">Type</span>
                <span class="badge badge-outline badge-sm uppercase">
                  {String.replace(@infraction.type, "_", " ")}
                </span>
              </div>
              <div class="flex justify-between gap-4">
                <span class="shrink-0 opacity-60">Date</span>
                <span class="min-w-0 max-w-[70%] text-right">
                  {format_datetime(@infraction.datetime_taken)}
                </span>
              </div>
              <div class="flex justify-between gap-4">
                <span class="shrink-0 opacity-60">Location</span>
                <span class="min-w-0 max-w-[70%] text-right break-words">
                  {@infraction.location}
                </span>
              </div>
              <div class="flex justify-between gap-4">
                <span class="shrink-0 opacity-60">File</span>
                <span class="min-w-0 max-w-[70%] break-all text-right font-mono text-xs">
                  {@infraction.photo.filename}
                </span>
              </div>
            </div>
            
    <!-- QR Code -->
            <div class="p-5 border-b border-base-300 flex flex-col items-center">
              <div class="w-36 h-36">
                <img src={qr_code_data_uri(@infraction.id)} class="w-full h-full" />
              </div>
              <p class="opacity-50 text-xs mt-2">Scan for mobile access</p>
            </div>
            
    <!-- Actions -->
            <div class="p-5 mt-auto hidden md:block">
              <a
                href={Radar.Photos.get_photo_url!(@infraction.photo, download: true)}
                download={@infraction.photo.filename}
                class="btn btn-primary btn-sm w-full"
              >
                Download Photo
              </a>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%A, %B %d, %Y at %I:%M:%S %p")
  end

  defp format_short_datetime(datetime) do
    Calendar.strftime(datetime, "%m/%d/%Y %I:%M %p")
  end

  defp short_id(id) do
    id
    |> to_string()
    |> String.slice(0, 8)
  end

  defp violation_severity(recorded_speed, authorized_speed) do
    diff = recorded_speed - authorized_speed

    cond do
      diff >= 25 -> "SEVERE"
      diff >= 15 -> "MAJOR"
      diff >= 5 -> "MODERATE"
      true -> "MINOR"
    end
  end

  defp severity_color(severity) do
    case severity do
      "SEVERE" -> "text-error"
      "MAJOR" -> "text-warning"
      "MODERATE" -> "text-warning"
      "MINOR" -> "text-info"
    end
  end

  defp qr_code_data_uri(infraction_id) do
    url = RadarWeb.Endpoint.url() <> "/infractions/#{infraction_id}"

    case url |> QRCode.create() |> QRCode.render(:svg) do
      {:ok, svg} -> "data:image/svg+xml;base64,#{Base.encode64(svg)}"
      _ -> ""
    end
  end
end
