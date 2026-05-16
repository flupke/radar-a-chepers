defmodule Radar.Infractions do
  @moduledoc """
  The Infractions context handles all speed ticket and infraction operations.
  """

  import Ecto.Query, warn: false
  alias Radar.{Infraction, Photo, Photos, Repo}

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
  Returns all infractions with preloaded photos.
  """
  def list_infractions(opts \\ []) do
    limit_value = Keyword.get(opts, :limit)
    offset_value = Keyword.get(opts, :offset, 0)
    sort_by = normalize_sort_by(Keyword.get(opts, :sort_by, :date))
    sort_dir = normalize_sort_dir(Keyword.get(opts, :sort_dir, :desc))

    Infraction
    |> order_by_sort(sort_by, sort_dir)
    |> maybe_limit(limit_value)
    |> maybe_offset(offset_value)
    |> preload(:photo)
    |> Repo.all()
  end

  @doc """
  Returns the total infraction count.
  """
  def count_infractions do
    Repo.aggregate(Infraction, :count, :id)
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

  def store_json_backup(attrs, %Photo{} = photo) when is_map(attrs) do
    Photos.store_infraction_json(photo, infraction_json_payload(attrs))
  end

  defp infraction_json_payload(%Infraction{} = infraction) do
    %{
      type: infraction.type,
      datetime_taken: NaiveDateTime.to_iso8601(infraction.datetime_taken),
      recorded_speed: infraction.recorded_speed,
      authorized_speed: infraction.authorized_speed,
      location: infraction.location
    }
  end

  defp infraction_json_payload(attrs) do
    %{
      type: Map.get(attrs, "type", "speed_ticket"),
      datetime_taken: attrs["datetime_taken"],
      recorded_speed: attrs["recorded_speed"],
      authorized_speed: attrs["authorized_speed"],
      location: attrs["location"]
    }
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit)

  defp maybe_offset(query, 0), do: query
  defp maybe_offset(query, offset), do: offset(query, ^offset)

  defp order_by_sort(query, sort_by, sort_dir) do
    field = sort_field(sort_by)

    case sort_by do
      :date ->
        order_by(query, [i], [{^sort_dir, field(i, ^field)}, desc: i.id])

      _ ->
        order_by(query, [i], [
          {^sort_dir, field(i, ^field)},
          desc: i.datetime_taken,
          desc: i.id
        ])
    end
  end

  defp sort_field(:date), do: :datetime_taken
  defp sort_field(:speed), do: :recorded_speed
  defp sort_field(:location), do: :location

  defp normalize_sort_by(sort_by) when sort_by in [:date, "date"], do: :date
  defp normalize_sort_by(sort_by) when sort_by in [:speed, "speed"], do: :speed
  defp normalize_sort_by(sort_by) when sort_by in [:location, "location"], do: :location
  defp normalize_sort_by(_sort_by), do: :date

  defp normalize_sort_dir(sort_dir) when sort_dir in [:asc, "asc"], do: :asc
  defp normalize_sort_dir(sort_dir) when sort_dir in [:desc, "desc"], do: :desc
  defp normalize_sort_dir(_sort_dir), do: :desc
end
