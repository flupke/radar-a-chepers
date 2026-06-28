defmodule RadarWeb.RadarConfigChannelTest do
  use RadarWeb.ChannelCase

  alias Radar.RadarConfigs
  alias RadarWeb.RadarConfigChannel
  alias RadarWeb.Presence

  @uploader_debug_topic "uploader_debug"
  @rd03d "rd03d"
  @ld2451 "ld2451"

  setup do
    Radar.RadarData.clear()
    :ok
  end

  test "get_config rejects uploader clients before device registration" do
    socket = join_uploader()

    ref = push(socket, "get_config", %{})

    assert_reply ref, :error, %{reason: "device_not_registered"}
  end

  test "get_config replies with config for the registered uploader device" do
    socket =
      join_uploader()
      |> register_device(@ld2451, true)

    ref = push(socket, "get_config", %{})

    assert_reply ref, :ok, %{
      device_type: @ld2451,
      capture_paused: false,
      aperture_angle: 90
    }
  end

  test "rejects a second registered uploader while one is active" do
    join_uploader()
    |> register_device(@rd03d, false)

    socket = join_uploader()

    ref =
      push(socket, "register_device", %{
        "device_type" => @ld2451,
        "test_mode" => true
      })

    assert_reply ref, :error, %{reason: "device_already_connected"}

    ref = push(socket, "get_config", %{})
    assert_reply ref, :error, %{reason: "device_not_registered"}
  end

  test "rejects unsupported registered device types" do
    socket = join_uploader()

    ref =
      push(socket, "register_device", %{
        "device_type" => "fake",
        "test_mode" => false
      })

    assert_reply ref, :error, %{reason: "unsupported_device_type"}
  end

  test "allows the active uploader to repeat the same device registration" do
    socket =
      join_uploader()
      |> register_device(@rd03d, false)

    ref =
      push(socket, "register_device", %{
        "device_type" => @rd03d,
        "test_mode" => false
      })

    assert_reply ref, :ok, %{device_type: @rd03d, test_mode: false}
  end

  test "pushes config updates only for the registered uploader device" do
    join_uploader()
    |> register_device(@ld2451, true)

    assert {:ok, _config} = RadarConfigs.update_config(@rd03d, %{capture_paused: true})
    refute_push "config_updated", %{device_type: @rd03d}

    assert {:ok, _config} = RadarConfigs.update_config(@ld2451, %{capture_paused: true})

    assert_push "config_updated", %{device_type: @ld2451, capture_paused: true}
  end

  test "replies to uploader ping health checks" do
    socket = join_uploader()

    ref = push(socket, "ping", %{})

    assert_reply ref, :ok, %{}
  end

  test "continues forwarding target data while capture is paused" do
    socket =
      join_uploader()
      |> register_device(@rd03d, false)

    assert {:ok, _config} = RadarConfigs.update_config(@rd03d, %{capture_paused: true})
    Phoenix.PubSub.subscribe(Radar.PubSub, "radar_data")

    push(socket, "target_data", %{"x" => 1, "y" => 2})

    assert_receive {:target_data, %{"x" => 1, "y" => 2}}
    assert Radar.RadarData.last_target() == %{"x" => 1, "y" => 2}
  end

  test "tracks registered uploader devices" do
    Phoenix.PubSub.subscribe(Radar.PubSub, Presence.uploader_topic())

    join_uploader()
    |> register_device(@ld2451, true)

    assert_receive %Phoenix.Socket.Broadcast{
      event: "presence_diff",
      payload: %{joins: %{"uploader" => %{metas: [meta | _]}}}
    }

    assert meta.device_type == @ld2451
    assert meta.test_mode == true
  end

  test "accepts live uploader logs" do
    Phoenix.PubSub.subscribe(Radar.PubSub, @uploader_debug_topic)

    socket =
      join_uploader()
      |> register_device(@rd03d, false)

    push(socket, "uploader_log", %{"message" => "radar booted", "level" => "debug"})

    assert_receive {:uploader_log, log}
    assert log.message == "radar booted"
    assert log.level == "debug"
  end

  test "ignores target frames submitted as uploader logs" do
    Phoenix.PubSub.subscribe(Radar.PubSub, @uploader_debug_topic)

    socket =
      join_uploader()
      |> register_device(@rd03d, false)

    push(socket, "uploader_log", %{
      "message" => "EVENTS: TARGET: 150 0 100",
      "level" => "info"
    })

    refute_receive {:uploader_log, _log}
  end

  defp join_uploader do
    assert {:ok, _reply, socket} =
             Phoenix.ChannelTest.socket(RadarWeb.UploaderSocket, "uploader_socket", %{})
             |> subscribe_and_join(RadarConfigChannel, "radar:config")

    socket
  end

  defp register_device(socket, device_type, test_mode) do
    ref =
      push(socket, "register_device", %{
        "device_type" => device_type,
        "test_mode" => test_mode
      })

    assert_reply ref, :ok, payload
    assert payload.device_type == device_type
    assert payload.test_mode == test_mode

    socket
  end
end
