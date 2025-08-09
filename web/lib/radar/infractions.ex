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

  @doc """
  Creates an infraction with the given attributes.
  """
  def create_infraction(attrs) do
    %Infraction{}
    |> Infraction.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an infraction.
  """
  def update_infraction(%Infraction{} = infraction, attrs) do
    infraction
    |> Infraction.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an infraction.
  """
  def delete_infraction(%Infraction{} = infraction) do
    Repo.delete(infraction)
  end

  @doc """
  Returns the count of infractions created today.
  """
  def count_infractions_today() do
    today = Date.utc_today()
    start_of_day = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")

    Infraction
    |> where([i], i.inserted_at >= ^start_of_day)
    |> Repo.aggregate(:count, :id)
  end
end
