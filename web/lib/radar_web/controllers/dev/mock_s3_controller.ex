defmodule RadarWeb.Dev.MockS3Controller do
  use RadarWeb, :controller

  def show(conn, %{"key" => encoded_key}) do
    with {:ok, key} <- Base.url_decode64(encoded_key),
         {:ok, data, content_type} <- Radar.MockS3Client.get_object(key) do
      conn
      |> put_resp_content_type(content_type, nil)
      |> send_resp(200, data)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end
end
