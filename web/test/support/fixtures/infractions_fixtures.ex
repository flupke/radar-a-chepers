defmodule Radar.InfractionsFixtures do
  @moduledoc """
  This module defines test fixtures for Infractions.
  """
  alias Radar.Infractions

  @doc """
  Generate an infraction.
  """
  def infraction_fixture(attrs \\ %{}) do
    {:ok, infraction} =
      attrs
      |> Enum.into(%{
        type: "speed_ticket",
        datetime_taken: ~N[2024-01-15 14:30:00],
        recorded_speed: 75,
        authorized_speed: 55,
        location: "Highway 101 Mile 42",
        photo_id: attrs[:photo_id] || raise("photo_id is required")
      })
      |> Infractions.create_speed_ticket()

    infraction
  end
end
