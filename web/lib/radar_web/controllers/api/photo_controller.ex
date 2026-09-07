defmodule RadarWeb.Api.PhotoController do
  use RadarWeb, :controller

  require Logger

  alias Radar.{Infractions, Photos}

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

  defp handle_photo_upload(
         conn,
         %{"photo" => photo_upload, "infraction" => infraction_data}
       ) do
    with {:ok, decoded_infraction} <- decode_infraction_data(infraction_data),
         {:ok, file_data} <- read_upload_file(photo_upload),
         {:ok, capture_id} <- capture_id(conn),
         {:ok, photo} <-
           create_photo_with_infraction(photo_upload, file_data, decoded_infraction, capture_id) do
      conn
      |> put_status(:created)
      |> json(%{
        id: photo.id,
        filename: photo.filename,
        tigris_key: photo.tigris_key,
        infraction_json_key: Photos.infraction_json_key(photo),
        infraction_id: hd(photo.infractions).id,
        url:
          case Photos.get_photo_url(photo) do
            {:ok, url} -> url
            _ -> nil
          end
      })
    else
      {:error, :capture_id_conflict} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "Capture ID already belongs to different photo or infraction data"})

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

  defp capture_id(conn) do
    case get_req_header(conn, "x-capture-id") do
      [] -> {:ok, nil}
      [id] when byte_size(id) in 1..200 -> {:ok, "client:" <> id}
      _ -> {:error, "Invalid capture ID"}
    end
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

  defp create_photo_with_infraction(upload, file_data, decoded_infraction, capture_id) do
    infraction_attrs = %{
      "datetime_taken" => decoded_infraction["datetime_taken"],
      "recorded_speed" => parse_integer(decoded_infraction["recorded_speed"]),
      "authorized_speed" => parse_integer(decoded_infraction["authorized_speed"]),
      "location" => decoded_infraction["location"]
    }

    fingerprint =
      :crypto.hash(:sha256, [
        file_data,
        Jason.encode!([
          upload.filename,
          upload.content_type,
          Enum.map(
            ~w(datetime_taken recorded_speed authorized_speed location),
            &infraction_attrs[&1]
          )
        ])
      ])
      |> Base.encode16(case: :lower)

    # Content identity also makes retries from older uploaders idempotent.
    capture_id = capture_id || "content:" <> fingerprint

    photo_attrs = %{
      "filename" => upload.filename,
      "content_type" => upload.content_type,
      "file_size" => byte_size(file_data),
      "capture_id" => capture_id,
      "capture_fingerprint" => fingerprint
    }

    case Photos.create_photo(photo_attrs, file_data) do
      {:ok, photo} ->
        infraction_attrs =
          Map.merge(infraction_attrs, %{
            "photo_id" => photo.id,
            "capture_id" => capture_id
          })

        log_json_backup_result(
          Infractions.store_json_backup(infraction_attrs, photo),
          photo.tigris_key
        )

        case Infractions.create_speed_ticket(infraction_attrs) do
          {:ok, infraction} ->
            {:ok, %{photo | infractions: [infraction]}}

          {:error, changeset} ->
            {:error, "Failed to create infraction: #{inspect(changeset.errors)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp log_json_backup_result({:ok, _json_key}, _infraction), do: :ok

  defp log_json_backup_result({:error, reason}, context) do
    Logger.warning("Failed to store infraction JSON backup for #{context}: #{inspect(reason)}")
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
