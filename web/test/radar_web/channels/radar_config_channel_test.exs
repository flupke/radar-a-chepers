defmodule RadarWeb.RadarConfigChannelTest do
  use RadarWeb.ChannelCase

  alias Radar.RadarConfigs
  alias RadarWeb.RadarConfigChannel

  @uploader_debug_topic "uploader_debug"

  test "get_config replies with capture pause state for uploader clients" do
    assert {:ok, _reply, socket} =
             Phoenix.ChannelTest.socket(RadarWeb.UploaderSocket, "uploader_socket", %{})
             |> subscribe_and_join(RadarConfigChannel, "radar:config")

    ref = push(socket, "get_config", %{})

    assert_reply ref, :ok, %{capture_paused: false}
  end

  test "pushes capture pause updates to joined uploader clients" do
    assert {:ok, _reply, _socket} =
             Phoenix.ChannelTest.socket(RadarWeb.UploaderSocket, "uploader_socket", %{})
             |> subscribe_and_join(RadarConfigChannel, "radar:config")

    assert {:ok, _config} = RadarConfigs.update_config(%{capture_paused: true})

    assert_push "config_updated", %{capture_paused: true}
  end

  test "continues forwarding target data while capture is paused" do
    assert {:ok, _reply, socket} =
             Phoenix.ChannelTest.socket(RadarWeb.UploaderSocket, "uploader_socket", %{})
             |> subscribe_and_join(RadarConfigChannel, "radar:config")

    assert {:ok, _config} = RadarConfigs.update_config(%{capture_paused: true})
    Phoenix.PubSub.subscribe(Radar.PubSub, "radar_data")

    push(socket, "target_data", %{"x" => 1, "y" => 2})

    assert_receive {:target_data, %{"x" => 1, "y" => 2}}
  end

  test "tracks uploader channel joins" do
    Phoenix.PubSub.subscribe(Radar.PubSub, @uploader_debug_topic)

    assert {:ok, _reply, _socket} =
             Phoenix.ChannelTest.socket(RadarWeb.UploaderSocket, "uploader_socket", %{})
             |> subscribe_and_join(RadarConfigChannel, "radar:config")

    assert_receive {:uploader_connected, true}
  end

  test "accepts live uploader logs" do
    Phoenix.PubSub.subscribe(Radar.PubSub, @uploader_debug_topic)

    assert {:ok, _reply, socket} =
             Phoenix.ChannelTest.socket(RadarWeb.UploaderSocket, "uploader_socket", %{})
             |> subscribe_and_join(RadarConfigChannel, "radar:config")

    assert_receive {:uploader_connected, true}

    push(socket, "uploader_log", %{"message" => "radar booted", "level" => "debug"})

    assert_receive {:uploader_log, log}
    assert log.message == "radar booted"
    assert log.level == "debug"
  end

  test "ignores target frames submitted as uploader logs" do
    Phoenix.PubSub.subscribe(Radar.PubSub, @uploader_debug_topic)

    assert {:ok, _reply, socket} =
             Phoenix.ChannelTest.socket(RadarWeb.UploaderSocket, "uploader_socket", %{})
             |> subscribe_and_join(RadarConfigChannel, "radar:config")

    assert_receive {:uploader_connected, true}

    push(socket, "uploader_log", %{
      "message" => "EVENTS: TARGET: 150 0 100",
      "level" => "info"
    })

    refute_receive {:uploader_log, _log}
  end
end
