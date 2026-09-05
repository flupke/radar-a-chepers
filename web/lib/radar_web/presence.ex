defmodule RadarWeb.Presence do
  @moduledoc false

  use Phoenix.Presence,
    otp_app: :radar,
    pubsub_server: Radar.PubSub

  @uploader_topic "uploader:config"
  @uploader_key "uploader"

  def uploader_topic, do: @uploader_topic
  def uploader_key, do: @uploader_key

  def track_uploader(pid \\ self(), meta \\ %{}) do
    meta =
      meta
      |> Map.new()
      |> Map.put(:online_at, DateTime.utc_now() |> DateTime.to_iso8601())

    track(pid, @uploader_topic, @uploader_key, meta)
  end

  def untrack_uploader(pid \\ self()) do
    untrack(pid, @uploader_topic, @uploader_key)
  end

  def uploader_connected? do
    @uploader_topic
    |> list()
    |> Map.has_key?(@uploader_key)
  end
end
