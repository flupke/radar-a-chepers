defmodule Radar.Photos do
  @moduledoc """
  The Photos context handles photo uploads to Tigris storage and database operations.
  """

  import Ecto.Query, warn: false
  alias Radar.Repo
  alias Radar.Photo

  @doc """
  Returns the list of recent photos with preloaded infractions.
  """
  def list_recent_photos(limit \\ 50) do
    Photo
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> preload(:infractions)
    |> Repo.all()
  end

  @doc """
  Gets a single photo with preloaded infractions.
  """
  def get_photo!(id) do
    Photo
    |> preload(:infractions)
    |> Repo.get!(id)
  end

  @doc """
  Creates a photo record and uploads the file to Tigris storage.
  """
  def create_photo(attrs, file_data) do
    tigris_key = Photo.generate_tigris_key(attrs["filename"])

    case upload_to_tigris(tigris_key, file_data, attrs["content_type"]) do
      :ok ->
        photo_attrs =
          Map.merge(attrs, %{
            "tigris_key" => tigris_key
          })

        %Photo{}
        |> Photo.upload_changeset(photo_attrs)
        |> Repo.insert()
        |> case do
          {:ok, photo} ->
            Phoenix.PubSub.broadcast(Radar.PubSub, "photos", {:new_photo, photo})
            {:ok, photo}

          error ->
            error
        end

      {:error, reason} ->
        {:error, "Upload failed: #{reason}"}
    end
  end

  @doc """
  Gets the public URL for a photo from Tigris storage.
  """
  def get_photo_url(photo) do
    # For testing: return local static file URL
    "/uploads/#{Path.basename(photo.tigris_key)}"
  end

  defp upload_to_tigris(key, file_data, _content_type) do
    # For testing: save to local priv/static/uploads directory
    upload_dir = Path.join([Application.app_dir(:radar, "priv"), "static", "uploads"])
    File.mkdir_p!(upload_dir)
    file_path = Path.join(upload_dir, Path.basename(key))

    case File.write(file_path, file_data) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes a photo from both database and Tigris storage.
  """
  def delete_photo(%Photo{} = photo) do
    # For testing: delete from local storage
    upload_dir = Path.join([Application.app_dir(:radar, "priv"), "static", "uploads"])
    file_path = Path.join(upload_dir, Path.basename(photo.tigris_key))

    case File.rm(file_path) do
      :ok -> Repo.delete(photo)
      # File already gone
      {:error, :enoent} -> Repo.delete(photo)
      {:error, reason} -> {:error, "Failed to delete file: #{reason}"}
    end
  end

  @doc """
  Returns the count of photos uploaded today.
  """
  def count_photos_today() do
    today = Date.utc_today()
    start_of_day = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")

    Photo
    |> where([p], p.inserted_at >= ^start_of_day)
    |> Repo.aggregate(:count, :id)
  end
end
