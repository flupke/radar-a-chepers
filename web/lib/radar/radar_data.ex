defmodule Radar.RadarData do
  @moduledoc false

  use Agent

  @topic "radar_data"

  def start_link(_opts) do
    Agent.start_link(fn -> nil end, name: __MODULE__)
  end

  def last_target do
    Agent.get(__MODULE__, & &1)
  end

  def update_target(payload) when is_map(payload) do
    Agent.update(__MODULE__, fn _target -> payload end)
    Phoenix.PubSub.broadcast(Radar.PubSub, @topic, {:target_data, payload})
  end

  def clear do
    Agent.update(__MODULE__, fn _target -> nil end)
  end
end
