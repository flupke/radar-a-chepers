defmodule Radar.S3 do
  @moduledoc false
  @callback put_object(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback get_object(binary()) :: {:ok, binary(), binary()} | {:error, term()}
  @callback stream_object(binary()) :: {:ok, Enumerable.t()} | {:error, term()}
  @callback delete_object(binary()) :: {:ok, map()} | {:error, term()}
  @callback presigned_url(binary(), keyword()) :: {:ok, binary()} | {:error, binary()}

  def put_object(object, body, opts) do
    ExAws.S3.put_object(bucket(), object, body, opts) |> ExAws.request()
  end

  def delete_object(key) do
    ExAws.S3.delete_object(bucket(), key) |> ExAws.request()
  end

  def get_object(key) do
    case ExAws.S3.get_object(bucket(), key) |> ExAws.request() do
      {:ok, %{body: body, headers: headers}} ->
        {:ok, body, content_type_from_headers(headers)}

      {:ok, %{body: body}} ->
        {:ok, body, "application/octet-stream"}

      error ->
        error
    end
  end

  def stream_object(key) do
    with {:ok, _metadata} <- ExAws.S3.head_object(bucket(), key) |> ExAws.request() do
      {:ok,
       bucket()
       |> ExAws.S3.download_file(key, :memory,
         chunk_size: 64 * 1024,
         max_concurrency: 1
       )
       |> ExAws.stream!()}
    end
  end

  def presigned_url(key, opts \\ []) do
    :s3 |> ExAws.Config.new() |> ExAws.S3.presigned_url(:get, bucket(), key, opts)
  end

  defp bucket do
    Application.fetch_env!(:radar, :s3_bucket)
  end

  defp content_type_from_headers(headers) do
    Enum.find_value(headers, "application/octet-stream", fn {key, value} ->
      if String.downcase(to_string(key)) == "content-type", do: value
    end)
  end
end
