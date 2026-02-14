defmodule Radar.Infraction do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "infractions" do
    field :type, :string, default: "speed_ticket"
    field :datetime_taken, :naive_datetime
    field :recorded_speed, :integer
    field :authorized_speed, :integer
    field :location, :string

    belongs_to :photo, Radar.Photo

    timestamps()
  end

  @doc false
  def changeset(infraction, attrs) do
    infraction
    |> cast(attrs, [
      :type,
      :datetime_taken,
      :recorded_speed,
      :authorized_speed,
      :location,
      :photo_id
    ])
    |> validate_required([
      :type,
      :datetime_taken,
      :recorded_speed,
      :authorized_speed,
      :location,
      :photo_id
    ])
    |> validate_inclusion(:type, ["speed_ticket"])
    |> validate_number(:recorded_speed, greater_than: 0)
    |> validate_number(:authorized_speed, greater_than: 0)
    |> validate_length(:location, max: 255)
    |> foreign_key_constraint(:photo_id)
  end

  @doc """
  Creates a changeset for a speed ticket infraction.
  """
  def speed_ticket_changeset(infraction, attrs) do
    infraction
    |> cast(attrs, [:datetime_taken, :recorded_speed, :authorized_speed, :location, :photo_id])
    |> put_change(:type, "speed_ticket")
    |> validate_required([
      :datetime_taken,
      :recorded_speed,
      :authorized_speed,
      :location,
      :photo_id
    ])
    |> validate_number(:recorded_speed, greater_than: 0)
    |> validate_number(:authorized_speed, greater_than: 0)
    |> validate_length(:location, max: 255)
    |> foreign_key_constraint(:photo_id)
  end
end
