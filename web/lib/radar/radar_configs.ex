defmodule Radar.RadarConfigs do
  @moduledoc """
  Context for managing radar configuration parameters.
  """

  alias Radar.Repo
  alias Radar.RadarConfig

  def supported_device_types, do: RadarConfig.supported_device_types()

  def get_config!(device_type) do
    device_type = validate_device_type!(device_type)

    Repo.get_by!(RadarConfig, device_type: device_type)
  end

  def update_config(device_type, params) do
    device_type = validate_device_type!(device_type)

    get_config!(device_type)
    |> RadarConfig.changeset(discard_device_type(params))
    |> Repo.update()
    |> case do
      {:ok, config} ->
        Phoenix.PubSub.broadcast(Radar.PubSub, "radar_config", {:config_updated, config})
        {:ok, config}

      error ->
        error
    end
  end

  def config_payload(device_type) when is_binary(device_type) do
    config_payload(device_type, get_config!(device_type))
  end

  def config_payload(device_type, %RadarConfig{} = config) do
    device_type = validate_device_type!(device_type)

    if config.device_type != device_type do
      raise ArgumentError,
            "expected #{device_type} radar config, got #{inspect(config.device_type)}"
    end

    %{
      device_type: config.device_type,
      authorized_speed: config.authorized_speed,
      min_dist: config.min_dist,
      max_dist: config.max_dist,
      trigger_cooldown: config.trigger_cooldown,
      aperture_angle: config.aperture_angle,
      capture_paused: config.capture_paused
    }
  end

  defp discard_device_type(params) when is_map(params) do
    Map.drop(params, [:device_type, "device_type"])
  end

  defp discard_device_type(params), do: params

  defp validate_device_type!(device_type) do
    if device_type in supported_device_types() do
      device_type
    else
      raise ArgumentError,
            "unsupported radar device_type #{inspect(device_type)}; expected one of: #{Enum.join(supported_device_types(), ", ")}"
    end
  end
end
