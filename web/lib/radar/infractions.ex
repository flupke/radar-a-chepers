defmodule Radar.Infractions do
  @moduledoc """
  The Infractions context handles all speed ticket and infraction operations.
  """

  import Ecto.Query, warn: false
  alias Radar.Repo
  alias Radar.Infraction

  @doc """
  Returns the list of recent infractions with preloaded photos.
  """
  def list_recent_infractions(limit \\ 50) do
    Infraction
    |> order_by(desc: :datetime_taken)
    |> limit(^limit)
    |> preload(:photo)
    |> Repo.all()
  end

  @doc """
  Gets a single infraction with preloaded photo.
  """
  def get_infraction!(id) do
    Infraction
    |> preload(:photo)
    |> Repo.get!(id)
  end

  @doc """
  Creates a speed ticket infraction.
  """
  def create_speed_ticket(attrs) do
    %Infraction{}
    |> Infraction.speed_ticket_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, infraction} ->
        Phoenix.PubSub.broadcast(Radar.PubSub, "infractions", {:new_infraction, infraction})
        {:ok, infraction}

      error ->
        error
    end
  end
end
