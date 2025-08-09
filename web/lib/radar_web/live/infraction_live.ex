defmodule RadarWeb.InfractionLive do
  use RadarWeb, :live_view

  alias Radar.Infractions
  alias Radar.Photos

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
      "SEVERE" -> "text-red-500"
      "MAJOR" -> "text-orange-500"
      "MODERATE" -> "text-yellow-500"
      "MINOR" -> "text-blue-500"
    end
  end
end
