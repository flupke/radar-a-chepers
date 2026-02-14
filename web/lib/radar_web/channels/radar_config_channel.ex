defmodule RadarWeb.RadarConfigChannel do
  @moduledoc false
  use RadarWeb, :channel

  alias Radar.RadarConfigs

  @impl true
  def join("radar:config", _payload, socket) do
    Phoenix.PubSub.subscribe(Radar.PubSub, "radar_config")
    {:ok, socket}
  end

  @impl true
  def handle_in("get_config", _payload, socket) do
    config = RadarConfigs.get_config!()
    {:reply, {:ok, RadarConfigs.config_payload(config)}, socket}
  end

  @impl true
  def handle_in("target_data", payload, socket) do
    Phoenix.PubSub.broadcast(Radar.PubSub, "radar_data", {:target_data, payload})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:config_updated, config}, socket) do
    push(socket, "config_updated", RadarConfigs.config_payload(config))
    {:noreply, socket}
  end
end
