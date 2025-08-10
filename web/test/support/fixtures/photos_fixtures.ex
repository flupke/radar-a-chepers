defmodule Radar.PhotosFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Radar.Photos` context.
  """

  alias Radar.Photos
  alias Radar.Photo
  alias Radar.Repo

  @doc """
  Generate a photo record with Tigris mock expectations.
  """
  def photo_fixture(attrs \\ %{}) do
    # Use the configured MockS3Client - no Mox expectations needed

    attrs =
      attrs
      |> Enum.into(%{
        "filename" => "test_photo_#{System.unique_integer([:positive])}.jpg",
        "data" => "test data",
        "content_type" => "image/jpeg",
        "file_size" => 1000
      })

    case Photos.create_photo(attrs) do
      {:ok, photo} -> photo
      {:error, reason} -> raise "Failed to create photo fixture: #{inspect(reason)}"
    end
  end

  @doc """
  Create a photo record directly in the database without Tigris operations.
  This is useful for tests that don't need the full upload flow.
  """
  def photo_fixture_direct(attrs \\ %{}) do
    attrs =
      attrs
      |> Enum.into(%{
        filename: "test_photo_#{System.unique_integer([:positive])}.jpg",
        tigris_key: "radar/photos/test_#{System.unique_integer([:positive])}.jpg",
        content_type: "image/jpeg",
        file_size: 1000
      })

    {:ok, photo} = Repo.insert(%Photo{} |> Photo.changeset(attrs))
    photo
  end

  @doc """
  Delete all photos from the test database.
  """
  def delete_all_photos do
    Repo.delete_all(Photo)
  end
end
