defmodule Radar.Photos do
  @moduledoc """
  The Photos context handles photo uploads to Tigris storage and database operations.
  """

  import Ecto.Query, warn: false
  alias Radar.Repo
  alias Radar.Photo

  def create_photo(attrs) do
    file_data = attrs["data"]

    if is_nil(file_data) do
      {:error, "Failed to upload to Tigris: :badarg"}
    else
      do_create_photo(attrs, file_data)
    end
  end

  defp do_create_photo(attrs, file_data) do
    filename = attrs["filename"]
    content_type = attrs["content_type"] || "image/jpeg"
    tigris_key = Photo.generate_tigris_key(filename)

    with {:ok, _} <- upload_to_tigris(tigris_key, file_data, content_type),
         photo_attrs = %{
           "filename" => filename,
           "tigris_key" => tigris_key,
           "content_type" => content_type,
           "file_size" => attrs["file_size"] || byte_size(file_data)
         },
         {:ok, photo} <- %Photo{} |> Photo.upload_changeset(photo_attrs) |> Repo.insert() do
      {:ok, photo}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        delete_from_tigris(tigris_key)
        {:error, changeset}

      {:error, reason} ->
        {:error, "Failed to upload to Tigris: #{inspect(reason)}"}
    end
  end

  @doc """
  Creates a photo record and uploads the file to Tigris storage.
  """
  def create_photo(attrs, file_data) do
    attrs_with_data = Map.put(attrs, "data", file_data)
    create_photo(attrs_with_data)
  end

  def get_photo_url(photo, opts \\ []) do
    s3_opts =
      if opts[:download] do
        [
          query_params: [
            {"response-content-disposition", "attachment; filename=\"#{photo.filename}\""}
          ]
        ]
      else
        []
      end

    s3_client().presigned_url(photo.tigris_key, s3_opts)
  end

  def get_photo_url!(photo, opts \\ []) do
    {:ok, url} = get_photo_url(photo, opts)
    url
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

  defp s3_client do
    Application.fetch_env!(:radar, :s3_client)
  end
end
