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
         "Infraction ##{String.pad_leading(to_string(infraction.id), 6, "0")}"
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
      <div class="h-screen bg-base-300 text-base-content flex flex-col overflow-hidden">
        <!-- Header -->
        <div class="navbar bg-primary shrink-0 px-6">
          <div class="flex-1">
            <h1 class="text-xl font-bold text-primary-content">
              Infraction #{String.pad_leading(to_string(@infraction.id), 6, "0")}
            </h1>
          </div>
          <div class="flex-none text-sm text-primary-content/70">
            {format_short_datetime(@infraction.datetime_taken)}
          </div>
        </div>

        <!-- Main Content -->
        <div class="flex-1 flex min-h-0">
          <!-- Photo -->
          <div class="flex-1 relative min-w-0">
            <img
              src={Radar.Photos.get_photo_url!(@infraction.photo)}
              alt="Speed camera capture"
              class="w-full h-full object-cover"
            />
            <div class="badge badge-error badge-lg absolute top-4 right-4 font-bold">
              VIOLATION
            </div>
          </div>

          <!-- Sidebar -->
          <div class="w-80 shrink-0 bg-base-200 border-l border-base-300 flex flex-col overflow-y-auto">
            <!-- Speed Stats -->
            <div class="stats stats-vertical shadow-none rounded-none border-b border-base-300">
              <div class="stat">
                <div class="stat-title">Recorded Speed</div>
                <div class="stat-value text-error">{@infraction.recorded_speed}</div>
                <div class="stat-desc">MPH</div>
              </div>
              <div class="stat">
                <div class="stat-title">Speed Limit</div>
                <div class="stat-value">{@infraction.authorized_speed}</div>
                <div class="stat-desc">MPH</div>
              </div>
              <div class="stat">
                <div class="stat-title">Violation</div>
                <div class="stat-value text-error text-2xl">
                  +{@infraction.recorded_speed - @infraction.authorized_speed} MPH
                </div>
                <div class={"stat-desc font-semibold #{severity_color(violation_severity(@infraction.recorded_speed, @infraction.authorized_speed))}"}>
                  {violation_severity(@infraction.recorded_speed, @infraction.authorized_speed)}
                </div>
              </div>
            </div>

            <!-- Case Info -->
            <div class="p-5 border-b border-base-300 space-y-3 text-sm">
              <div class="flex justify-between">
                <span class="opacity-60">Case ID</span>
                <span class="font-mono">#{String.pad_leading(to_string(@infraction.id), 6, "0")}</span>
              </div>
              <div class="flex justify-between">
                <span class="opacity-60">Type</span>
                <span class="badge badge-outline badge-sm uppercase">
                  {String.replace(@infraction.type, "_", " ")}
                </span>
              </div>
              <div class="flex justify-between">
                <span class="opacity-60">Date</span>
                <span class="text-right max-w-[60%]">{format_datetime(@infraction.datetime_taken)}</span>
              </div>
              <div class="flex justify-between">
                <span class="opacity-60">Location</span>
                <span class="text-right max-w-[60%]">{@infraction.location}</span>
              </div>
              <div class="flex justify-between">
                <span class="opacity-60">File</span>
                <span class="font-mono text-xs">{@infraction.photo.filename}</span>
              </div>
            </div>

            <!-- QR Code -->
            <div class="p-5 border-b border-base-300 flex flex-col items-center">
              <div class="w-36 h-36 [&>svg]:w-full [&>svg]:h-full">
                {qr_code_svg(@infraction.id)}
              </div>
              <p class="opacity-50 text-xs mt-2">Scan for mobile access</p>
            </div>

            <!-- Actions -->
            <div class="p-5 mt-auto">
              <a
                href={Radar.Photos.get_photo_url!(@infraction.photo)}
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

  def qr_code_svg(infraction_id) do
    url = RadarWeb.Endpoint.url() <> "/infractions/#{infraction_id}"

    case url |> QRCode.create() |> QRCode.render(:svg) do
      {:ok, svg} ->
        svg =
          Regex.replace(
            ~r/(<svg)\s+width="(\d+)"\s+height="(\d+)"/,
            svg,
            ~S(\1 viewBox="0 0 \2 \3")
          )

        {:safe, svg}

      _ ->
        ""
    end
  end
end
