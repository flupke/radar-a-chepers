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
    from(p in Photo,
      order_by: [desc: p.inserted_at, desc: p.id],
      limit: ^limit,
      preload: [:infractions]
    )
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
  Gets a single photo with preloaded infractions and adds Tigris URL.
  """
  def get_photo(id) do
    case Repo.get(Photo, id) do
      nil ->
        {:error, :not_found}

      photo ->
        case get_photo_url(photo) do
          {:ok, url} -> {:ok, Map.put(photo, :tigris_url, url)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Creates a photo record and uploads the file to Tigris storage.
  """
  def create_photo(attrs) do
    file_data = attrs["data"]
    filename = attrs["filename"]
    content_type = attrs["content_type"] || "image/jpeg"

    if is_nil(file_data) do
      {:error, "Failed to upload to Tigris: :badarg"}
    else
      tigris_key = Photo.generate_tigris_key(filename)

      case upload_to_tigris(tigris_key, file_data, content_type) do
        {:ok, _} ->
          photo_attrs = %{
            "filename" => filename,
            "tigris_key" => tigris_key,
            "content_type" => content_type,
            "file_size" => attrs["file_size"] || byte_size(file_data)
          }

          %Photo{}
          |> Photo.upload_changeset(photo_attrs)
          |> Repo.insert()
          |> case do
            {:ok, photo} ->
              {:ok, photo}

            error ->
              # Clean up the uploaded file if database insert fails
              delete_from_tigris(tigris_key)
              error
          end

        {:error, reason} ->
          {:error, "Failed to upload to Tigris: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Creates a photo record and uploads the file to Tigris storage.
  """
  def create_photo(attrs, file_data) do
    attrs_with_data = Map.put(attrs, "data", file_data)
    create_photo(attrs_with_data)
  end

  def get_photo_url(photo) do
    {:ok, s3_client().public_url(photo.tigris_key)}
  end

  def get_photo_url!(photo) do
    s3_client().public_url(photo.tigris_key)
  end

  @doc """
  Deletes a photo from both database and Tigris storage.
  """
  def delete_photo(%Photo{} = photo) do
    with {:ok, _} <- delete_from_tigris(photo.tigris_key),
         {:ok, _} <- Repo.delete(photo) do
      {:ok, photo}
    else
      {:error, reason} -> {:error, "Failed to delete photo: #{inspect(reason)}"}
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

  # Private functions for Tigris S3 operations

  defp upload_to_tigris(key, file_data, content_type) do
    case s3_client().put_object(key, file_data, content_type: content_type) do
      {:ok, _} -> {:ok, :uploaded}
      error -> error
    end
  end

  defp delete_from_tigris(key) do
    case s3_client().delete_object(key) do
      {:ok, _} -> {:ok, :deleted}
      error -> error
    end
  end

  @doc """
  S3 client module. Can be mocked for testing.
  """
  def s3_client do
    Application.fetch_env!(:radar, :s3_client)
  end
end
