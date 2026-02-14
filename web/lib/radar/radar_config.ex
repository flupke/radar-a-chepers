defmodule Radar.RadarConfig do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "radar_configs" do
    field :authorized_speed, :integer, default: 25
    field :min_dist, :integer, default: 0
    field :max_dist, :integer, default: 10_000
    field :trigger_cooldown, :integer, default: 1000

    timestamps()
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:authorized_speed, :min_dist, :max_dist, :trigger_cooldown])
    |> validate_required([:authorized_speed, :min_dist, :max_dist, :trigger_cooldown])
    |> validate_number(:authorized_speed, greater_than: 0)
    |> validate_number(:min_dist, greater_than_or_equal_to: 0)
    |> validate_number(:max_dist, greater_than: 0)
    |> validate_number(:trigger_cooldown, greater_than_or_equal_to: 0)
  end
end
