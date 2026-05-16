defmodule Radar.RadarConfigsTest do
  use Radar.DataCase

  alias Radar.RadarConfigs

  test "config payload includes uploader capture state" do
    config = RadarConfigs.get_config!()

    assert RadarConfigs.config_payload(config).aperture_angle == 90
    assert RadarConfigs.config_payload(config).capture_paused == false
  end

  test "update_config persists aperture angle" do
    assert {:ok, config} =
             RadarConfigs.update_config(%{
               authorized_speed: 50,
               min_dist: 500,
               max_dist: 12_000,
               trigger_cooldown: 1500,
               aperture_angle: 75
             })

    assert config.aperture_angle == 75
    assert RadarConfigs.config_payload(config).aperture_angle == 75
  end

  test "update_config persists capture pause state" do
    assert {:ok, config} = RadarConfigs.update_config(%{capture_paused: true})

    assert config.capture_paused == true
    assert RadarConfigs.config_payload(config).capture_paused == true
  end

  test "update_config rejects max distance below min distance" do
    assert {:error, changeset} =
             RadarConfigs.update_config(%{
               authorized_speed: 50,
               min_dist: 5000,
               max_dist: 4000,
               trigger_cooldown: 1500,
               aperture_angle: 75
             })

    assert "must be greater than or equal to min distance" in errors_on(changeset).max_dist
  end
end
