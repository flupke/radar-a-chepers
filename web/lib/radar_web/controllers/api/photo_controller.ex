defmodule RadarWeb.Api.PhotoController do
  use RadarWeb, :controller

  alias Radar.Photos
  alias Radar.Infractions

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

      api_key in configured_api_keys() ->
        {:ok, api_key}

      true ->
        {:error, "Invalid API key"}
    end
  end

  defp handle_photo_upload(conn, %{"photo" => photo_upload, "infraction" => infraction_data}) do
    with {:ok, decoded_infraction} <- decode_infraction_data(infraction_data),
         {:ok, file_data} <- read_upload_file(photo_upload),
         {:ok, photo} <- create_photo_with_infraction(photo_upload, file_data, decoded_infraction) do
      conn
      |> put_status(:created)
      |> json(%{
        id: photo.id,
        filename: photo.filename,
        tigris_key: photo.tigris_key,
        infraction_id: hd(photo.infractions).id,
        url:
          case Photos.get_photo_url(photo) do
            {:ok, url} -> url
            _ -> nil
          end
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

  defp decode_infraction_data(data) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, "Invalid infraction data"}
      {:error, _reason} -> {:error, "Invalid infraction JSON"}
    end
  end

  defp decode_infraction_data(data) when is_map(data), do: {:ok, data}
  defp decode_infraction_data(_data), do: {:error, "Invalid infraction data"}

  defp create_photo_with_infraction(upload, file_data, decoded_infraction) do
    photo_attrs = %{
      "filename" => upload.filename,
      "content_type" => upload.content_type,
      "file_size" => byte_size(file_data)
    }

    case Photos.create_photo(photo_attrs, file_data) do
      {:ok, photo} ->
        infraction_attrs =
          Map.merge(decoded_infraction, %{
            "photo_id" => photo.id,
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

  defp configured_api_keys() do
    Application.get_env(:radar, :api_keys)
  end
end
