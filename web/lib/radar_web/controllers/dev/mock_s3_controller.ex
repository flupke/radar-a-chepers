defmodule RadarWeb.Dev.MockS3Controller do
  use RadarWeb, :controller

  def show(conn, %{"key" => encoded_key}) do
    with {:ok, key} <- Base.url_decode64(encoded_key),
         [{^key, data, content_type}] <- :ets.lookup(:mock_s3_store, key) do
      conn
      |> put_resp_content_type(content_type)
      |> send_resp(200, data)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end
end
