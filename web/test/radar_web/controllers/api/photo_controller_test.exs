defmodule RadarWeb.Api.PhotoControllerTest do
  use RadarWeb.ConnCase
  use ExUnit.Case

  alias Radar.{Infractions, Photos, RadarConfigs}
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
    test "retries reuse one photo and infraction, including older clients", %{upload: upload} do
      for capture_id <- [nil, "camera-capture-123"] do
        send_upload = fn -> upload_capture(upload, @valid_infraction_data, capture_id) end
        first = send_upload.() |> json_response(201)
        second = send_upload.() |> json_response(201)

        assert second["id"] == first["id"]
        assert second["infraction_id"] == first["infraction_id"]
        assert second["tigris_key"] == first["tigris_key"]
      end

      assert Repo.aggregate(Radar.Photo, :count) == 2
      assert Repo.aggregate(Radar.Infraction, :count) == 2
    end

    test "rejects reuse of a capture ID for changed data", %{upload: upload} do
      original =
        upload_capture(upload, @valid_infraction_data, "capture-conflict") |> json_response(201)

      changed = Map.put(@valid_infraction_data, "recorded_speed", "99")

      assert upload_capture(upload, changed, "capture-conflict") |> json_response(409)
      assert Repo.aggregate(Radar.Photo, :count) == 1
      assert Infractions.get_infraction!(original["infraction_id"]).recorded_speed == 78

      File.write!(upload.path, "different photo")

      assert upload_capture(upload, @valid_infraction_data, "capture-conflict")
             |> json_response(409)

      assert Repo.aggregate(Radar.Infraction, :count) == 1
    end

    test "retry finishes a capture whose photo was saved before an interrupted request", %{
      upload: upload
    } do
      first =
        upload_capture(upload, @valid_infraction_data, "interrupted-capture")
        |> json_response(201)

      Repo.get!(Radar.Infraction, first["infraction_id"]) |> Repo.delete!()

      retried =
        upload_capture(upload, @valid_infraction_data, "interrupted-capture")
        |> json_response(201)

      assert retried["id"] == first["id"]
      assert Repo.aggregate(Radar.Photo, :count) == 1
      assert Repo.aggregate(Radar.Infraction, :count) == 1
    end

    test "concurrent retries create only one capture", %{upload: upload} do
      # Initialize the mock's shared storage before concurrent requests.
      Radar.MockS3Client.put_object("concurrency-setup", "", [])

      responses =
        1..4
        |> Task.async_stream(fn _ ->
          upload_capture(upload, @valid_infraction_data, "concurrent-capture")
          |> json_response(201)
        end)
        |> Enum.map(fn {:ok, response} -> response end)

      assert responses |> Enum.map(& &1["infraction_id"]) |> Enum.uniq() |> length() == 1
      assert Repo.aggregate(Radar.Photo, :count) == 1
      assert Repo.aggregate(Radar.Infraction, :count) == 1
    end

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

      assert %{
               "id" => photo_id,
               "infraction_id" => infraction_id,
               "filename" => "test_photo.jpg",
               "infraction_json_key" => infraction_json_key,
               "url" => url
             } =
               json_response(conn, 201)

      assert photo = Repo.get!(Radar.Photo, photo_id)
      assert infraction = Infractions.get_infraction!(infraction_id)

      assert photo.id == infraction.photo_id
      assert infraction.recorded_speed == 78
      assert infraction.authorized_speed == 55
      assert infraction.location == "Highway 101 Mile 42"

      # Verify the photo record has the Tigris key
      assert String.starts_with?(photo.tigris_key, "radar/photos/")
      assert String.ends_with?(photo.tigris_key, ".jpg")
      assert infraction_json_key == Photos.infraction_json_key(photo)

      assert String.starts_with?(url, "/dev/photos/")
      expected_image = File.read!(upload.path)

      assert {:ok, ^expected_image, "image/jpeg"} =
               Radar.MockS3Client.get_object(photo.tigris_key)

      assert {:ok, infraction_json, "application/json"} =
               Radar.MockS3Client.get_object(infraction_json_key)

      assert Jason.decode!(infraction_json) == %{
               "type" => "speed_ticket",
               "datetime_taken" => "2024-01-15T14:30:00",
               "recorded_speed" => 78,
               "authorized_speed" => 55,
               "location" => "Highway 101 Mile 42"
             }

      :ets.delete(:mock_s3_store, photo.tigris_key)
      :ets.delete(:mock_s3_store, infraction_json_key)

      assert {:ok, ^expected_image, "image/jpeg"} =
               Radar.MockS3Client.get_object(photo.tigris_key)

      assert {:ok, ^infraction_json, "application/json"} =
               Radar.MockS3Client.get_object(infraction_json_key)
    end

    @tag capture_log: true
    test "keeps the photo and infraction when JSON backup storage fails", %{
      conn: conn,
      upload: upload
    } do
      Process.put(:mock_s3_fail_json_put, true)
      on_exit(fn -> Process.delete(:mock_s3_fail_json_put) end)

      conn =
        conn
        |> put_req_header("x-api-key", @valid_api_key)
        |> post("/api/photos", %{
          "photo" => upload,
          "infraction" => @valid_infraction_data
        })

      assert %{
               "id" => photo_id,
               "infraction_id" => infraction_id,
               "infraction_json_key" => infraction_json_key
             } = json_response(conn, 201)

      assert photo = Repo.get!(Radar.Photo, photo_id)
      assert infraction = Infractions.get_infraction!(infraction_id)
      assert infraction.photo_id == photo.id

      assert {:ok, _image, "image/jpeg"} = Radar.MockS3Client.get_object(photo.tigris_key)
      assert {:error, :enoent} = Radar.MockS3Client.get_object(infraction_json_key)
    end

    test "accepts already captured photos while all radar capture is paused", %{
      conn: conn,
      upload: upload
    } do
      for device_type <- RadarConfigs.supported_device_types() do
        assert {:ok, _} = RadarConfigs.update_config(device_type, %{capture_paused: true})
      end

      conn =
        conn
        |> put_req_header("x-api-key", @valid_api_key)
        |> post("/api/photos", %{
          "photo" => upload,
          "infraction" => @valid_infraction_data
        })

      assert %{"id" => photo_id, "infraction_id" => infraction_id} = json_response(conn, 201)
      assert Repo.get!(Radar.Photo, photo_id)
      assert Infractions.get_infraction!(infraction_id).photo_id == photo_id
    end

    test "returns an infraction error without deleting the uploaded photo", %{
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
      assert [photo] = Repo.all(Radar.Photo)
      assert {:ok, _image, "image/jpeg"} = Radar.MockS3Client.get_object(photo.tigris_key)

      assert {:ok, infraction_json, "application/json"} =
               Radar.MockS3Client.get_object(Photos.infraction_json_key(photo))

      assert Jason.decode!(infraction_json) == %{
               "type" => "speed_ticket",
               "datetime_taken" => "invalid-date",
               "recorded_speed" => 0,
               "authorized_speed" => 55,
               "location" => ""
             }

      assert Infractions.list_recent_infractions() == []
    end

    test "returns error without creating a photo if infraction JSON is invalid", %{
      conn: conn,
      upload: upload
    } do
      conn =
        conn
        |> put_req_header("x-api-key", @valid_api_key)
        |> post("/api/photos", %{
          "photo" => upload,
          "infraction" => "{not-json"
        })

      assert json_response(conn, 422)["error"] == "Invalid infraction JSON"
      assert Repo.all(Radar.Photo) == []
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

  defp upload_capture(upload, data, capture_id) do
    conn = build_conn() |> put_req_header("x-api-key", @valid_api_key)
    conn = if capture_id, do: put_req_header(conn, "x-capture-id", capture_id), else: conn
    post(conn, "/api/photos", %{"photo" => upload, "infraction" => data})
  end
end
