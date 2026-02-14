defmodule Radar.S3 do
  @callback put_object(binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback delete_object(binary()) :: {:ok, map()} | {:error, term()}
  @callback presigned_url(binary(), keyword()) :: {:ok, binary()} | {:error, binary()}

  def put_object(object, body, opts) do
    ExAws.S3.put_object(bucket(), object, body, opts) |> ExAws.request()
  end

  def delete_object(key) do
    ExAws.S3.delete_object(bucket(), key) |> ExAws.request()
  end

  def presigned_url(key, opts \\ []) do
    :s3 |> ExAws.Config.new() |> ExAws.S3.presigned_url(:get, bucket(), key, opts)
  end

  defp bucket do
    Application.fetch_env!(:radar, :s3_bucket)
  end
end
