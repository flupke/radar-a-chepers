defmodule RadarWeb.Api.PhotoController do
  use RadarWeb, :controller

  alias Radar.Photos
  alias Radar.Infractions

  @api_keys Application.compile_env(:radar, :api_keys, ["radar-dev-key"])

  def create(conn, params) do
    case authenticate_api_key(conn) do
      {:ok, _key} ->
        handle_photo_upload(conn, params)

      {:error, reason} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: reason})
    end
  end

  defp authenticate_api_key(conn) do
    api_key = get_req_header(conn, "x-api-key") |> List.first()

    cond do
      is_nil(api_key) ->
        {:error, "API key required"}

      api_key in @api_keys ->
        {:ok, api_key}

      true ->
        {:error, "Invalid API key"}
    end
  end

  defp handle_photo_upload(conn, %{"photo" => photo_upload, "infraction" => infraction_data}) do
    with {:ok, file_data} <- read_upload_file(photo_upload),
         {:ok, photo} <- create_photo_with_infraction(photo_upload, file_data, infraction_data) do
      conn
      |> put_status(:created)
      |> json(%{
        id: photo.id,
        filename: photo.filename,
        tigris_key: photo.tigris_key,
        infraction_id: hd(photo.infractions).id,
        url: Photos.get_photo_url(photo)
      })
    else
      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: reason})
    end
  end

  defp handle_photo_upload(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing photo or infraction data"})
  end

  defp read_upload_file(%Plug.Upload{path: path}) do
    case File.read(path) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, "Failed to read upload: #{reason}"}
    end
  end

  defp create_photo_with_infraction(upload, file_data, infraction_data) do
    photo_attrs = %{
      "filename" => upload.filename,
      "content_type" => upload.content_type,
      "file_size" => byte_size(file_data)
    }

    case Photos.create_photo(photo_attrs, file_data) do
      {:ok, photo} ->
        # First decode the JSON string if it's a string
        decoded_infraction =
          case infraction_data do
            data when is_binary(data) -> Jason.decode!(data)
            data when is_map(data) -> data
          end

        infraction_attrs =
          Map.merge(decoded_infraction, %{
            "photo_id" => photo.id,
            "datetime_taken" => parse_datetime(decoded_infraction["datetime_taken"]),
            "recorded_speed" => parse_integer(decoded_infraction["recorded_speed"]),
            "authorized_speed" => parse_integer(decoded_infraction["authorized_speed"]),
            "location" => decoded_infraction["location"]
          })

        case Infractions.create_speed_ticket(infraction_attrs) do
          {:ok, infraction} ->
            {:ok, %{photo | infractions: [infraction]}}

          {:error, changeset} ->
            Photos.delete_photo(photo)
            {:error, "Failed to create infraction: #{inspect(changeset.errors)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp parse_integer(value) when is_integer(value), do: value
  defp parse_integer(_), do: 0

  defp parse_datetime(datetime_string) when is_binary(datetime_string) do
    case NaiveDateTime.from_iso8601(datetime_string) do
      {:ok, datetime} -> datetime
      {:error, _} -> NaiveDateTime.utc_now()
    end
  end

  defp parse_datetime(_), do: NaiveDateTime.utc_now()
end
