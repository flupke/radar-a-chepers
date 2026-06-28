defmodule Radar.RadarConfigsTest do
  use Radar.DataCase

  alias Radar.RadarConfig
  alias Radar.RadarConfigs

  @rd03d "rd03d"
  @ld2451 "ld2451"

  test "migrated configs exist for each supported radar device" do
    assert RadarConfigs.supported_device_types() == [@rd03d, @ld2451]

    rd03d_config = RadarConfigs.get_config!(@rd03d)
    ld2451_config = RadarConfigs.get_config!(@ld2451)

    assert rd03d_config.device_type == @rd03d
    assert ld2451_config.device_type == @ld2451
    assert ld2451_config.authorized_speed == 25
    assert ld2451_config.min_dist == 0
    assert ld2451_config.max_dist == 10_000
    assert ld2451_config.trigger_cooldown == 1000
    assert ld2451_config.aperture_angle == 90
    assert ld2451_config.capture_paused == false
  end

  test "changeset requires a supported device type" do
    changeset =
      RadarConfig.changeset(%RadarConfig{}, %{
        device_type: "fake",
        authorized_speed: 50,
        min_dist: 500,
        max_dist: 12_000,
        trigger_cooldown: 1500,
        aperture_angle: 75,
        capture_paused: false
      })

    assert "is invalid" in errors_on(changeset).device_type
  end

  test "get_config! requires an explicit supported device type" do
    assert_raise ArgumentError, ~r/unsupported radar device_type/, fn ->
      RadarConfigs.get_config!("fake")
    end
  end

  test "config payload includes device type and uploader capture state" do
    config = RadarConfigs.get_config!(@rd03d)

    assert RadarConfigs.config_payload(@rd03d, config).device_type == @rd03d
    assert RadarConfigs.config_payload(@rd03d, config).aperture_angle == 90
    assert RadarConfigs.config_payload(@rd03d, config).capture_paused == false
  end

  test "update_config persists aperture angle for the requested device" do
    assert {:ok, config} =
             RadarConfigs.update_config(@ld2451, %{
               authorized_speed: 50,
               min_dist: 500,
               max_dist: 12_000,
               trigger_cooldown: 1500,
               aperture_angle: 75
             })

    assert config.device_type == @ld2451
    assert config.aperture_angle == 75
    assert RadarConfigs.config_payload(@ld2451, config).aperture_angle == 75
    assert RadarConfigs.get_config!(@rd03d).aperture_angle == 90
  end

  test "update_config persists capture pause state" do
    assert {:ok, config} = RadarConfigs.update_config(@rd03d, %{capture_paused: true})

    assert config.capture_paused == true
    assert RadarConfigs.config_payload(@rd03d, config).capture_paused == true
  end

  test "update_config rejects max distance below min distance" do
    assert {:error, changeset} =
             RadarConfigs.update_config(@rd03d, %{
               authorized_speed: 50,
               min_dist: 5000,
               max_dist: 4000,
               trigger_cooldown: 1500,
               aperture_angle: 75
             })

    assert "must be greater than or equal to min distance" in errors_on(changeset).max_dist
  end
end
