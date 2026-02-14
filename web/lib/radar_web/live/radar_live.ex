defmodule RadarWeb.RadarLive do
  use RadarWeb, :live_view

  alias Radar.Infractions

  @display_duration 8000

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Radar.PubSub, "infractions")
    end

    infractions = Infractions.list_recent_infractions(50)

    socket =
      socket
      |> assign(:current_index, 0)
      |> assign(:current_infraction, List.first(infractions))
      |> schedule_next_infraction()

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-base-300 text-base-content font-mono">
      <%= if @current_infraction do %>
        <div class="relative w-full h-full">
          <img
            src={
              case Radar.Photos.get_photo_url(@current_infraction.photo) do
                {:ok, url} -> url
                _ -> "/images/placeholder.jpg"
              end
            }
            alt="Speed camera capture"
            class="w-full h-full object-cover"
          />

          <div class="absolute inset-0 pointer-events-none">
            <div class="absolute top-0 left-0 right-0 bg-neutral/80 px-8 py-4">
              <div class="flex justify-between items-center text-xl">
                <div class="badge badge-error badge-lg font-bold">SPEED VIOLATION</div>
                <div class="text-sm opacity-70">
                  {Calendar.strftime(@current_infraction.datetime_taken, "%m/%d/%Y %I:%M:%S %p")}
                </div>
              </div>
            </div>

            <div class="absolute bottom-0 left-0 right-0 bg-neutral/80 px-8 py-6">
              <div class="grid grid-cols-3 gap-8">
                <div class="space-y-2">
                  <div class="text-sm opacity-60 uppercase tracking-wide">RECORDED SPEED</div>
                  <div class="text-4xl font-bold">
                    {@current_infraction.recorded_speed} MPH
                  </div>
                  <div class="text-sm opacity-60 uppercase tracking-wide">SPEED LIMIT</div>
                  <div class="text-2xl font-bold">
                    {@current_infraction.authorized_speed} MPH
                  </div>
                  <div class="text-sm opacity-60 uppercase tracking-wide">VIOLATION</div>
                  <div class="text-xl font-bold text-error">
                    +{@current_infraction.recorded_speed - @current_infraction.authorized_speed} MPH
                  </div>
                </div>

                <div class="space-y-2">
                  <div class="text-sm opacity-60 uppercase tracking-wide">LOCATION</div>
                  <div class="text-lg font-bold">{@current_infraction.location}</div>
                  <div class="text-sm opacity-60 uppercase tracking-wide">CASE TYPE</div>
                  <div class="text-lg font-bold uppercase">
                    {String.replace(@current_infraction.type, "_", " ")}
                  </div>
                  <div class="text-sm opacity-60 uppercase tracking-wide">CASE ID</div>
                  <div class="text-lg font-bold">#{@current_infraction.id}</div>
                </div>

                <div class="flex flex-col items-end">
                  <div class="text-sm opacity-60 uppercase tracking-wide mb-2">CASE DETAILS</div>
                  <.link
                    navigate={~p"/infractions/#{@current_infraction.id}"}
                    class="block w-32 h-32 pointer-events-auto"
                  >
                    <img src={qr_code_data_uri(@current_infraction.id)} class="w-full h-full" />
                  </.link>
                </div>
              </div>
            </div>
          </div>
        </div>
      <% else %>
        <div class="flex items-center justify-center h-full">
          <div class="text-center">
            <div class="text-6xl mb-4">📷</div>
            <div class="text-2xl font-bold">RADAR SYSTEM ACTIVE</div>
            <div class="text-lg mt-2 opacity-60">Waiting for infractions...</div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  def handle_info({:new_infraction, infraction}, socket) do
    infraction = Radar.Repo.preload(infraction, :photo)

    {:noreply,
     socket
     |> assign(:current_infraction, infraction)
     |> assign(:current_index, 0)
     |> schedule_next_infraction()}
  end

  def handle_info(:advance_infraction, socket) do
    infractions = Infractions.list_recent_infractions(50)

    if infractions != [] do
      next_index = rem(socket.assigns.current_index + 1, length(infractions))

      {:noreply,
       socket
       |> assign(:current_index, next_index)
       |> assign(:current_infraction, Enum.at(infractions, next_index))
       |> schedule_next_infraction()}
    else
      {:noreply, assign(socket, :current_infraction, nil)}
    end
  end

  defp schedule_next_infraction(socket) do
    if ref = socket.assigns[:timer_ref], do: Process.cancel_timer(ref)
    ref = Process.send_after(self(), :advance_infraction, @display_duration)
    assign(socket, :timer_ref, ref)
  end

  defp qr_code_data_uri(infraction_id) do
    url = RadarWeb.Endpoint.url() <> "/infractions/#{infraction_id}"

    case url |> QRCode.create() |> QRCode.render(:svg) do
      {:ok, svg} -> "data:image/svg+xml;base64,#{Base.encode64(svg)}"
      _ -> ""
    end
  end
end
