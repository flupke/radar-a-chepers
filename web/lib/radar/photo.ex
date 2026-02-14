defmodule Radar.Photo do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  schema "photos" do
    field :filename, :string
    field :file_path, :string
    field :tigris_key, :string
    field :content_type, :string
    field :file_size, :integer

    has_many :infractions, Radar.Infraction

    timestamps()
  end

  @doc """
  Creates a changeset for uploading a photo to Tigris storage.
  """
  def upload_changeset(photo, attrs) do
    photo
    |> cast(attrs, [:filename, :tigris_key, :content_type, :file_size])
    |> validate_required([:filename, :tigris_key, :content_type])
    |> validate_length(:filename, max: 255)
    |> validate_number(:file_size, greater_than: 0)
  end

  @doc """
  Generates a unique Tigris key for the photo.
  """
  def generate_tigris_key(filename) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    extension = Path.extname(filename)
    random_string = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

    "radar/photos/#{timestamp}_#{random_string}#{extension}"
  end
end
