defmodule Radar.RadarConfigs do
  @moduledoc """
  Context for managing radar configuration parameters.
  """

  alias Radar.Repo
  alias Radar.RadarConfig

  def get_config! do
    Repo.one!(RadarConfig)
  end

  def update_config(params) do
    get_config!()
    |> RadarConfig.changeset(params)
    |> Repo.update()
    |> case do
      {:ok, config} ->
        Phoenix.PubSub.broadcast(Radar.PubSub, "radar_config", {:config_updated, config})
        {:ok, config}

      error ->
        error
    end
  end

  def config_payload(%RadarConfig{} = config) do
    %{
      authorized_speed: config.authorized_speed,
      min_dist: config.min_dist,
      max_dist: config.max_dist,
      trigger_cooldown: config.trigger_cooldown
    }
  end
end
