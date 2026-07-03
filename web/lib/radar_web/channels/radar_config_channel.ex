defmodule RadarWeb.RadarConfigChannel do
  @moduledoc false
  use RadarWeb, :channel

  require Logger

  alias Radar.RadarData
  alias Radar.RadarConfigs
  alias RadarWeb.ActiveRadar

  @uploader_debug_topic "uploader_debug"

  @impl true
  def join("radar:config", _payload, socket) do
    Phoenix.PubSub.subscribe(Radar.PubSub, "radar_config")
    {:ok, socket}
  end

  @impl true
  def handle_in(
        "register_device",
        payload,
        %{assigns: %{registered_device_type: current_device_type, test_mode: current_test_mode}} =
          socket
      ) do
    with {:ok, device_type, test_mode} <- parse_registration(payload) do
      if current_device_type == device_type and current_test_mode == test_mode do
        {:reply, {:ok, %{device_type: device_type, test_mode: test_mode}}, socket}
      else
        {:reply, {:error, %{reason: "device_already_connected"}}, socket}
      end
    else
      {:error, :unsupported_device_type} ->
        {:reply, {:error, %{reason: "unsupported_device_type"}}, socket}

      {:error, :invalid_registration} ->
        {:reply, {:error, %{reason: "invalid_registration"}}, socket}
    end
  end

  def handle_in("register_device", payload, socket) do
    with {:ok, device_type, test_mode} <- parse_registration(payload),
         :ok <- ActiveRadar.register(self(), device_type, test_mode),
         {:ok, _ref} <- track_registered_uploader(device_type, test_mode) do
      socket =
        socket
        |> assign(:registered_device_type, device_type)
        |> assign(:test_mode, test_mode)

      {:reply, {:ok, %{device_type: device_type, test_mode: test_mode}}, socket}
    else
      {:error, :device_already_connected} ->
        {:reply, {:error, %{reason: "device_already_connected"}}, socket}

      {:error, :unsupported_device_type} ->
        {:reply, {:error, %{reason: "unsupported_device_type"}}, socket}

      {:error, :invalid_registration} ->
        {:reply, {:error, %{reason: "invalid_registration"}}, socket}

      {:error, reason} ->
        ActiveRadar.unregister(self())
        Logger.warning("Failed to register uploader device: #{inspect(reason)}")
        {:reply, {:error, %{reason: "device_registration_failed"}}, socket}
    end
  end

  @impl true
  def handle_in(
        "get_config",
        _payload,
        %{assigns: %{registered_device_type: device_type}} = socket
      ) do
    config = RadarConfigs.get_config!(device_type)
    {:reply, {:ok, RadarConfigs.config_payload(device_type, config)}, socket}
  end

  def handle_in("get_config", _payload, socket) do
    {:reply, {:error, %{reason: "device_not_registered"}}, socket}
  end

  @impl true
  def handle_in("ping", _payload, socket) do
    {:reply, {:ok, %{}}, socket}
  end

  @impl true
  def handle_in(
        "target_data",
        payload,
        %{assigns: %{registered_device_type: _device_type}} = socket
      ) do
    RadarData.update_target(payload)
    {:noreply, socket}
  end

  def handle_in("target_data", _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_in(
        "uploader_log",
        payload,
        %{assigns: %{registered_device_type: _device_type}} = socket
      ) do
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

  def handle_in("uploader_log", _payload, socket), do: {:noreply, socket}

  @impl true
  def handle_info(
        {:config_updated, config},
        %{assigns: %{registered_device_type: device_type}} = socket
      ) do
    if config.device_type == device_type do
      push(socket, "config_updated", RadarConfigs.config_payload(device_type, config))
    end

    {:noreply, socket}
  end

  def handle_info({:config_updated, _config}, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, %{assigns: %{registered_device_type: _device_type}}) do
    ActiveRadar.unregister(self())
    RadarWeb.Presence.untrack_uploader(self())
    :ok
  end

  def terminate(_reason, _socket), do: :ok

  defp parse_registration(%{"device_type" => device_type, "test_mode" => test_mode})
       when is_binary(device_type) and is_boolean(test_mode) do
    if device_type in RadarConfigs.supported_device_types() do
      {:ok, device_type, test_mode}
    else
      {:error, :unsupported_device_type}
    end
  end

  defp parse_registration(_payload), do: {:error, :invalid_registration}

  defp track_registered_uploader(device_type, test_mode) do
    RadarWeb.Presence.track_uploader(self(), %{
      device_type: device_type,
      test_mode: test_mode
    })
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
