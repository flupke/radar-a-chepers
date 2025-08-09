defmodule RadarWeb.RadarLive do
  use RadarWeb, :live_view

  alias Radar.Photos
  alias Radar.Infractions
  alias Radar.QrCodes

  # 8 seconds in milliseconds
  @default_display_duration 8000

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Radar.PubSub, "infractions")
    end

    recent_infractions = Infractions.list_recent_infractions(50)

    socket =
      socket
      |> assign(:display_duration, @default_display_duration)
      |> assign(:current_index, 0)
      |> assign(:infractions_empty?, recent_infractions == [])
      |> assign(:total_infractions, length(recent_infractions))
      |> assign(:current_infraction, List.first(recent_infractions))
      |> assign(:all_infractions, recent_infractions)
      |> stream(:infractions, recent_infractions)

    # Start the auto-advance timer if we have infractions
    socket =
      if recent_infractions != [] do
        schedule_next_photo(socket)
      else
        socket
      end

    {:ok, socket}
  end

  def handle_info({:new_infraction, infraction}, socket) do
    infraction = Radar.Repo.preload(infraction, :photo)
    new_all_infractions = [infraction | socket.assigns.all_infractions]

    {:noreply,
     socket
     |> assign(:infractions_empty?, false)
     |> assign(:total_infractions, socket.assigns.total_infractions + 1)
     |> assign(:current_infraction, infraction)
     |> assign(:current_index, 0)
     |> assign(:all_infractions, new_all_infractions)
     |> stream_insert(:infractions, infraction, at: 0)
     |> maybe_start_timer()}
  end

  def handle_info(:advance_photo, socket) do
    # Get all infractions from the assign and advance to next
    all_infractions = socket.assigns.all_infractions

    if all_infractions != [] do
      next_index = rem(socket.assigns.current_index + 1, length(all_infractions))
      next_infraction = Enum.at(all_infractions, next_index)

      {:noreply,
       socket
       |> assign(:current_index, next_index)
       |> assign(:current_infraction, next_infraction)
       |> schedule_next_photo()}
    else
      {:noreply, socket}
    end
  end

  defp schedule_next_photo(socket) do
    Process.send_after(self(), :advance_photo, socket.assigns.display_duration)
    socket
  end

  defp maybe_start_timer(socket) do
    # Only start timer if we don't have infractions yet and now we do
    if socket.assigns.infractions_empty? do
      schedule_next_photo(socket)
    else
      socket
    end
  end

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%m/%d/%Y %I:%M:%S %p")
  end

  defp generate_qr_code(infraction_id) do
    case QrCodes.generate_infraction_qr_base64(infraction_id) do
      {:ok, qr_base64} -> qr_base64
      {:error, _reason} -> nil
    end
  end
end
