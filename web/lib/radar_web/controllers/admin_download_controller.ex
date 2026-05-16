defmodule RadarWeb.AdminDownloadController do
  use RadarWeb, :controller

  alias Radar.{Infractions, Photos}

  @infractions_per_page 100

  def photos_zip(conn, params) do
    page = parse_page(params["page"])
    all_photos? = params["scope"] == "all"
    sort_by = parse_sort_by(params["sort"])
    sort_dir = parse_sort_dir(params["dir"])

    conn =
      conn
      |> put_resp_content_type("application/zip")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="#{archive_filename(page, all_photos?)}")
      )
      |> send_chunked(200)

    case Radar.ZipStream.send(
           conn,
           infraction_photo_entries(page, all_photos?, sort_by, sort_dir)
         ) do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  defp infraction_photo_entries(_page, true, sort_by, sort_dir) do
    Stream.unfold(0, fn offset ->
      case list_infractions(offset, sort_by, sort_dir) do
        [] -> nil
        infractions -> {infractions, offset + @infractions_per_page}
      end
    end)
    |> Stream.flat_map(& &1)
    |> Stream.flat_map(&photo_zip_entry/1)
  end

  defp infraction_photo_entries(page, false, sort_by, sort_dir) do
    list_infraction_photo_entries(page, sort_by, sort_dir)
  end

  defp list_infraction_photo_entries(page, sort_by, sort_dir) do
    ((page - 1) * @infractions_per_page)
    |> list_infractions(sort_by, sort_dir)
    |> Enum.flat_map(&photo_zip_entry/1)
  end

  defp list_infractions(offset, sort_by, sort_dir) do
    Infractions.list_infractions(
      limit: @infractions_per_page,
      offset: offset,
      sort_by: sort_by,
      sort_dir: sort_dir
    )
  end

  defp photo_zip_entry(infraction) do
    case Photos.stream_photo_object(infraction.photo) do
      {:ok, stream} ->
        [
          %{
            name: zip_entry_name(infraction),
            stream: stream,
            size: infraction.photo.file_size || 0
          }
        ]

      {:error, _reason} ->
        []
    end
  end

  defp zip_entry_name(infraction) do
    infraction.id
    |> to_string()
    |> String.slice(0, 8)
    |> then(&"#{&1}_#{safe_filename(infraction.photo.filename)}")
  end

  defp safe_filename(filename) do
    String.replace(filename, ~r/[^A-Za-z0-9._-]/, "_")
  end

  defp archive_filename(_page, true), do: "infraction-photos-all.zip"
  defp archive_filename(page, false), do: "infraction-photos-page-#{page}.zip"

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {page, _rest} when page > 0 -> page
      _ -> 1
    end
  end

  defp parse_page(_page), do: 1

  defp parse_sort_by(sort_by) when sort_by in ["date", "speed", "location"] do
    String.to_existing_atom(sort_by)
  end

  defp parse_sort_by(_sort_by), do: :date

  defp parse_sort_dir(sort_dir) when sort_dir in ["asc", "desc"] do
    String.to_existing_atom(sort_dir)
  end

  defp parse_sort_dir(_sort_dir), do: :desc
end
