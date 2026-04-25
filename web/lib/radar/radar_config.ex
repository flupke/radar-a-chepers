defmodule Radar.RadarConfig do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "radar_configs" do
    field :authorized_speed, :integer, default: 25
    field :min_dist, :integer, default: 0
    field :max_dist, :integer, default: 10_000
    field :trigger_cooldown, :integer, default: 1000
    field :aperture_angle, :integer, default: 90

    timestamps()
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:authorized_speed, :min_dist, :max_dist, :trigger_cooldown, :aperture_angle])
    |> validate_required([
      :authorized_speed,
      :min_dist,
      :max_dist,
      :trigger_cooldown,
      :aperture_angle
    ])
    |> validate_number(:authorized_speed, greater_than: 0)
    |> validate_number(:min_dist, greater_than_or_equal_to: 0)
    |> validate_number(:max_dist, greater_than: 0)
    |> validate_number(:trigger_cooldown, greater_than_or_equal_to: 0)
    |> validate_number(:aperture_angle, greater_than: 0, less_than_or_equal_to: 180)
    |> validate_distance_order()
  end

  defp validate_distance_order(changeset) do
    min_dist = get_field(changeset, :min_dist)
    max_dist = get_field(changeset, :max_dist)

    if is_number(min_dist) and is_number(max_dist) and max_dist < min_dist do
      add_error(changeset, :max_dist, "must be greater than or equal to min distance")
    else
      changeset
    end
  end
end
