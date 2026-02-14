defmodule Radar.MockS3Client do
  @moduledoc """
  Mock S3 client for development and testing that implements the S3 behaviour.
  Stores uploaded files in an ETS table and serves them via a dev controller.
  """

  @behaviour Radar.S3

  @table :mock_s3_store

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:set, :public, :named_table])
      _ -> @table
    end
  end

  @impl true
  def put_object(key, data, opts) do
    ensure_table()
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")
    :ets.insert(@table, {key, data, content_type})
    {:ok, %{}}
  end

  @impl true
  def delete_object(key) do
    ensure_table()
    :ets.delete(@table, key)
    {:ok, %{}}
  end

  @seed_images %{
    "seed_1" => "/images/seed_1.jpg",
    "seed_2" => "/images/seed_2.jpg",
    "seed_3" => "/images/seed_3.jpg",
    "seed_4" => "/images/seed_4.jpg",
    "seed_5" => "/images/seed_5.jpg"
  }

  @impl true
  def presigned_url(key, _opts \\ []) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, _data, _ct}] -> {:ok, "/dev/photos/#{Base.url_encode64(key)}"}
      [] -> {:ok, seed_image_url(key)}
    end
  end

  defp seed_image_url(key) do
    Enum.find_value(@seed_images, fn {prefix, path} ->
      if String.contains?(key, prefix), do: path
    end) || "/images/seed_1.jpg"
  end
end
