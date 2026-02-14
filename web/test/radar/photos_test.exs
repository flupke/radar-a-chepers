defmodule Radar.PhotosTest do
  use Radar.DataCase, async: true

  alias Radar.Photos
  alias Radar.Photo

  describe "create_photo/2 with Tigris integration" do
    test "successfully uploads photo to Tigris and creates database record" do
      upload_params = %{
        "filename" => "test_speed_camera.jpg",
        # JPEG header bytes
        "data" => <<255, 216, 255, 224>>,
        "content_type" => "image/jpeg",
        "file_size" => 12_345
      }

      assert {:ok, photo} = Photos.create_photo(upload_params)

      # Verify database record
      assert photo.filename == "test_speed_camera.jpg"
      assert photo.content_type == "image/jpeg"
      assert photo.file_size == 12_345
      assert String.starts_with?(photo.tigris_key, "radar/photos/")
      assert String.ends_with?(photo.tigris_key, ".jpg")
      refute is_nil(photo.tigris_key)
    end

    test "validates required upload parameters" do
      # Test with missing data (should cause badarg when trying to get byte_size)
      invalid_params = %{
        "filename" => "test.jpg",
        "data" => nil,
        "content_type" => "image/jpeg"
      }

      assert {:error, reason} = Photos.create_photo(invalid_params)
      assert reason =~ "Failed to upload to Tigris: :badarg"
    end
  end

  describe "get_photo_url/1" do
    test "generates presigned URL for existing photo" do
      # Create photo record directly
      {:ok, photo} =
        Repo.insert(%Photo{
          filename: "test.jpg",
          tigris_key: "radar/photos/test-123.jpg",
          content_type: "image/jpeg",
          file_size: 1000
        })

      # In test environment, get_photo_url returns a test URL without mock
      assert {:ok, url} = Photos.get_photo_url(photo)
      assert String.starts_with?(url, "/images/seed_")
    end
  end
end
