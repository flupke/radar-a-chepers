defmodule Radar.ZipStreamTest do
  use ExUnit.Case, async: true

  import Phoenix.ConnTest

  test "streams entries into a readable zip archive" do
    entries = [
      %{name: "one.txt", stream: ["hel", "lo"], size: 5},
      %{name: "nested/two.txt", stream: [["two"], " data"], size: 8}
    ]

    assert {:ok, conn} = Radar.ZipStream.send(chunked_zip_conn(), entries)
    assert {:ok, files} = :zip.extract(conn.resp_body, [:memory])

    assert {~c"one.txt", "hello"} in files
    assert {~c"nested/two.txt", "two data"} in files
  end

  test "streams an empty zip archive" do
    assert {:ok, conn} = Radar.ZipStream.send(chunked_zip_conn(), [])
    assert {:ok, []} = :zip.extract(conn.resp_body, [:memory])
  end

  test "skips malformed entries" do
    entries = [
      %{name: "valid.txt", stream: ["valid"], size: 5},
      %{name: "missing-stream.txt", size: 0}
    ]

    assert {:ok, conn} = Radar.ZipStream.send(chunked_zip_conn(), entries)
    assert {:ok, files} = :zip.extract(conn.resp_body, [:memory])

    assert files == [{~c"valid.txt", "valid"}]
  end

  defp chunked_zip_conn do
    build_conn()
    |> Plug.Conn.put_resp_content_type("application/zip")
    |> Plug.Conn.send_chunked(200)
  end
end
