defmodule RadarWeb.RadarConfigChannel do
  @moduledoc false
  use RadarWeb, :channel

  require Logger

  alias Radar.RadarData
  alias Radar.RadarConfigs

  @uploader_debug_topic "uploader_debug"
  @impl true
  def join("radar:config", _payload, socket) do
    case RadarWeb.Presence.track_uploader(self()) do
      {:ok, _ref} -> :ok
      {:error, reason} -> Logger.warning("Failed to track uploader presence: #{inspect(reason)}")
    end

    Phoenix.PubSub.subscribe(Radar.PubSub, "radar_config")
    {:ok, socket}
  end

  @impl true
  def handle_in("get_config", _payload, socket) do
    config = RadarConfigs.get_config!()
    {:reply, {:ok, RadarConfigs.config_payload(config)}, socket}
  end

  @impl true
  def handle_in("ping", _payload, socket) do
    {:reply, {:ok, %{}}, socket}
  end

  @impl true
  def handle_in("target_data", payload, socket) do
    RadarData.update_target(payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("uploader_log", payload, socket) do
    log = uploader_log(payload)

    unless target_message?(log.message) do
      Phoenix.PubSub.broadcast(
        Radar.PubSub,
        @uploader_debug_topic,
        {:uploader_log, log}
      )
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:config_updated, config}, socket) do
    push(socket, "config_updated", RadarConfigs.config_payload(config))
    {:noreply, socket}
  end

  defp uploader_log_message(%{"message" => message}), do: message
  defp uploader_log_message(%{"line" => message}), do: message
  defp uploader_log_message(payload), do: inspect(payload)

  defp uploader_log_level(%{"level" => level}), do: level
  defp uploader_log_level(_payload), do: "info"

  defp uploader_log(payload) do
    %{
      id: System.unique_integer([:positive]),
      at: DateTime.utc_now() |> DateTime.truncate(:second),
      level: normalize_text(uploader_log_level(payload), "info"),
      message: normalize_text(uploader_log_message(payload), "")
    }
  end

  defp normalize_text(value, default) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> default
      text -> String.slice(text, 0, 500)
    end
  end

  defp normalize_text(_value, default), do: default

  defp target_message?(message) when is_binary(message),
    do: String.starts_with?(message, "EVENTS: TARGET: ")

  defp target_message?(_message), do: false
end
