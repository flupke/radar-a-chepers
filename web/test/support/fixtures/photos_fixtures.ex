defmodule Radar.PhotosFixtures do
  @moduledoc """
  This module defines test fixtures for Photos.
  """
  alias Radar.Photos
  alias Radar.Repo
  alias Radar.Photo

  @doc """
  Generate a photo.
  """
  def photo_fixture(attrs \\ %{}) do
    # Convert all keys to strings to avoid mixed key errors
    string_attrs =
      attrs
      |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)

    # Extract filename from attrs before merging
    filename =
      Map.get(string_attrs, "filename") || "test_photo_#{System.unique_integer()}.jpg"

    photo_attrs =
      %{
        "filename" => filename,
        "content_type" => "image/jpeg",
        "file_size" => 1024
      }
      |> Map.merge(string_attrs)

    {:ok, photo} = Photos.create_photo(photo_attrs, "test data")

    photo
  end

  @doc """
  Delete all photos.
  """
  def delete_all_photos do
    Repo.delete_all(Photo)
  end
end
