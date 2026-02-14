defmodule Radar.MockS3Client do
  @moduledoc """
  Mock S3 client for development and testing that implements the S3 behaviour.
  Returns fake presigned URLs without making any external requests.
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

  @seed_images %{
    "seed_1" => "/images/seed_1.jpg",
    "seed_2" => "/images/seed_2.jpg",
    "seed_3" => "/images/seed_3.jpg",
    "seed_4" => "/images/seed_4.jpg",
    "seed_5" => "/images/seed_5.jpg"
  }

  @impl true
  def presigned_url(_method, key, _opts) do
    url =
      Enum.find_value(@seed_images, fn {prefix, path} ->
        if String.contains?(key, prefix), do: path
      end) || "/images/seed_1.jpg"

    {:ok, url}
  end
end
