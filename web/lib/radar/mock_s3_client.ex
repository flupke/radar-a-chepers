defmodule Radar.MockS3Client do
  @moduledoc """
  Mock S3 client for development and testing that implements the S3 behaviour.
  Stores uploaded files in an ETS table and on disk, then serves them via a dev
  controller.
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
    :ok = write_object_to_disk(key, data)
    :ets.insert(@table, {key, data, content_type})
    {:ok, %{}}
  end

  @impl true
  def delete_object(key) do
    ensure_table()
    :ets.delete(@table, key)
    File.rm(object_path(key))
    {:ok, %{}}
  end

  @impl true
  def get_object(key) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, data, content_type}] ->
        {:ok, data, content_type}

      [] ->
        read_object_from_disk(key)
    end
  end

  @impl true
  def stream_object(key) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, data, _content_type}] ->
        {:ok, binary_stream(data)}

      [] ->
        path = object_path(key)

        if File.exists?(path) do
          {:ok, File.stream!(path, [], 64 * 1024)}
        else
          {:error, :enoent}
        end
    end
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
      [] -> presigned_disk_or_seed_url(key)
    end
  end

  defp presigned_disk_or_seed_url(key) do
    if File.exists?(object_path(key)) do
      {:ok, "/dev/photos/#{Base.url_encode64(key)}"}
    else
      {:ok, seed_image_url(key)}
    end
  end

  defp seed_image_url(key) do
    Enum.find_value(@seed_images, fn {prefix, path} ->
      if String.contains?(key, prefix), do: path
    end) || "/images/seed_1.jpg"
  end

  defp write_object_to_disk(key, data) do
    path = object_path(key)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, data)
    end
  end

  defp read_object_from_disk(key) do
    case File.read(object_path(key)) do
      {:ok, data} -> {:ok, data, content_type_for_key(key)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp binary_stream(data) do
    Stream.unfold(data, fn
      "" ->
        nil

      data ->
        chunk_size = min(byte_size(data), 64 * 1024)
        <<chunk::binary-size(chunk_size), rest::binary>> = data
        {chunk, rest}
    end)
  end

  defp object_path(key) do
    Path.join(storage_dir(), Base.url_encode64(key, padding: false))
  end

  defp storage_dir do
    Application.get_env(:radar, :mock_s3_dir) ||
      Path.expand("../../priv/static/uploads/mock_s3", __DIR__)
  end

  defp content_type_for_key(key) do
    cond do
      String.ends_with?(key, [".jpg", ".jpeg"]) -> "image/jpeg"
      String.ends_with?(key, ".png") -> "image/png"
      true -> "application/octet-stream"
    end
  end
end
