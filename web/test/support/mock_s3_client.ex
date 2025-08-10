defmodule Radar.MockS3Client do
  @moduledoc """
  Mock S3 client for testing that implements the S3Behaviour interface.
  """

  @behaviour Radar.S3

  @impl true
  def put_object(_key, _data, _opts) do
    {:ok, %{}}
  end

  @impl true
  def delete_object(_key) do
    {:ok, %{}}
  end

  @impl true
  def presigned_url(_method, key, _opts) do
    {:ok, "https://test.tigris.dev/radar-photos/#{key}"}
  end
end
