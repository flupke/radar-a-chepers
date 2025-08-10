defmodule RadarWeb.Api.PhotoControllerTest do
  use RadarWeb.ConnCase
  use ExUnit.Case

  alias Radar.Photos
  alias Radar.Infractions
  alias Radar.Repo

  @valid_api_key "radar-dev-key"
  @invalid_api_key "invalid-key"

  @valid_infraction_data %{
    "datetime_taken" => "2024-01-15T14:30:00",
    "recorded_speed" => "78",
    "authorized_speed" => "55",
    "location" => "Highway 101 Mile 42"
  }

  @invalid_infraction_data %{
    "datetime_taken" => "invalid-date",
    "recorded_speed" => "not-a-number",
    "authorized_speed" => "55",
    "location" => ""
  }

  setup do
    # Clean up any existing photos/infractions
    Repo.delete_all(Radar.Infraction)
    Repo.delete_all(Radar.Photo)

    # Create a test photo file
    test_image_data = <<137, 80, 78, 71, 13, 10, 26, 10>> <> :crypto.strong_rand_bytes(1024)

    upload = %Plug.Upload{
      path: "/tmp/test_photo.jpg",
      filename: "test_photo.jpg",
      content_type: "image/jpeg"
    }

    # Write test data to temp file
    File.write!(upload.path, test_image_data)

    on_exit(fn -> File.rm(upload.path) end)

    %{upload: upload}
  end

  describe "POST /api/photos" do
    test "rejects requests without an API key", %{conn: conn} do
      conn = post(conn, "/api/photos", %{})
      assert json_response(conn, 401)["error"] == "API key required"
    end

    test "rejects requests with an invalid API key", %{conn: conn, upload: upload} do
      conn =
        conn
        |> put_req_header("x-api-key", @invalid_api_key)
        |> post("/api/photos", %{
          "photo" => upload,
          "infraction" => @valid_infraction_data
        })

      assert json_response(conn, 401)["error"] == "Invalid API key"
    end

    test "creates a photo and infraction with valid data", %{conn: conn, upload: upload} do
      # Uses the configured MockS3Client - no explicit mocking needed

      conn =
        conn
        |> put_req_header("x-api-key", @valid_api_key)
        |> post("/api/photos", %{
          "photo" => upload,
          "infraction" => @valid_infraction_data
        })

      assert %{"id" => photo_id, "infraction_id" => infraction_id, "filename" => "test_photo.jpg"} =
               json_response(conn, 201)

      assert photo = Photos.get_photo!(photo_id)
      assert infraction = Infractions.get_infraction!(infraction_id)

      assert photo.id == infraction.photo_id
      assert infraction.recorded_speed == 78
      assert infraction.authorized_speed == 55
      assert infraction.location == "Highway 101 Mile 42"

      # Verify the photo record has the Tigris key
      assert String.starts_with?(photo.tigris_key, "radar/photos/")
      assert String.ends_with?(photo.tigris_key, ".jpg")
    end

    test "returns error and rolls back transaction if infraction data is invalid", %{
      conn: conn,
      upload: upload
    } do
      # Uses the configured MockS3Client - no explicit mocking needed

      conn =
        conn
        |> put_req_header("x-api-key", @valid_api_key)
        |> post("/api/photos", %{
          "photo" => upload,
          "infraction" => @invalid_infraction_data
        })

      assert json_response(conn, 422)["error"] =~ "Failed to create infraction"
      # Photo should be rolled back
      assert Photos.list_recent_photos() == []
      assert Infractions.list_recent_infractions() == []
    end

    test "returns error if missing photo or infraction data in request", %{upload: upload} do
      conn =
        build_conn()
        |> put_req_header("x-api-key", @valid_api_key)
        |> post("/api/photos", %{"photo" => upload})

      assert json_response(conn, 400)["error"] == "Missing photo or infraction data"

      conn =
        build_conn()
        |> put_req_header("x-api-key", @valid_api_key)
        |> post("/api/photos", %{"infraction" => @valid_infraction_data})

      assert json_response(conn, 400)["error"] == "Missing photo or infraction data"
    end

    test "handles file read errors gracefully", %{conn: conn} do
      # Create an upload with non-existent file
      bad_upload = %Plug.Upload{
        path: "/tmp/non_existent_file.jpg",
        filename: "bad_photo.jpg",
        content_type: "image/jpeg"
      }

      conn =
        conn
        |> put_req_header("x-api-key", @valid_api_key)
        |> post("/api/photos", %{
          "photo" => bad_upload,
          "infraction" => @valid_infraction_data
        })

      response = json_response(conn, 422)
      assert %{"error" => error_message} = response
      assert String.contains?(error_message, "Failed to read upload")
    end
  end
end
