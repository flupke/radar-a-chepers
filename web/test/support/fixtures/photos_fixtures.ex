defmodule Radar.PhotosFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Radar.Photos` context.
  """

  alias Radar.Photos

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
end
