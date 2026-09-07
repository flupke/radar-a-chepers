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
    case attrs["capture_id"] && Repo.get_by(Photo, capture_id: attrs["capture_id"]) do
      %Photo{} = photo -> verify_capture(photo, attrs)
      _ -> persist_photo(attrs, file_data)
    end
  end

  defp persist_photo(attrs, file_data) do
    filename = attrs["filename"]
    content_type = attrs["content_type"] || "image/jpeg"

    tigris_key =
      if fingerprint = attrs["capture_fingerprint"] do
        "radar/photos/captures/#{fingerprint}#{Path.extname(filename)}"
      else
        Photo.generate_tigris_key(filename)
      end

    with {:ok, _} <- upload_to_tigris(tigris_key, file_data, content_type),
         photo_attrs = %{
           "filename" => filename,
           "tigris_key" => tigris_key,
           "content_type" => content_type,
           "file_size" => attrs["file_size"] || byte_size(file_data),
           "capture_id" => attrs["capture_id"],
           "capture_fingerprint" => attrs["capture_fingerprint"]
         },
         {:ok, photo} <-
           %Photo{}
           |> Photo.upload_changeset(photo_attrs)
           |> Repo.insert(on_conflict: :nothing, conflict_target: :capture_id) do
      if capture_id = attrs["capture_id"] do
        verify_capture(Repo.get_by!(Photo, capture_id: capture_id), attrs)
      else
        {:ok, photo}
      end
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}

      {:error, reason} ->
        {:error, "Failed to upload to Tigris: #{inspect(reason)}"}
    end
  end

  defp verify_capture(photo, attrs) do
    if photo.capture_fingerprint == attrs["capture_fingerprint"] do
      {:ok, photo}
    else
      {:error, :capture_id_conflict}
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

  def get_photo_object(%Photo{} = photo) do
    s3_client().get_object(photo.tigris_key)
  end

  def stream_photo_object(%Photo{} = photo) do
    s3_client().stream_object(photo.tigris_key)
  end

  def infraction_json_key(%Photo{} = photo) do
    Path.rootname(photo.tigris_key) <> ".json"
  end

  def store_infraction_json(%Photo{} = photo, payload) when is_map(payload) do
    with {:ok, json} <- Jason.encode(payload),
         {:ok, _} <-
           upload_to_tigris(infraction_json_key(photo), json <> "\n", "application/json") do
      {:ok, infraction_json_key(photo)}
    end
  end

  # Private functions for Tigris S3 operations

  defp upload_to_tigris(key, file_data, content_type) do
    case s3_client().put_object(key, file_data, content_type: content_type) do
      {:ok, _} -> {:ok, :uploaded}
      error -> error
    end
  end

  defp s3_client do
    Application.fetch_env!(:radar, :s3_client)
  end
end
