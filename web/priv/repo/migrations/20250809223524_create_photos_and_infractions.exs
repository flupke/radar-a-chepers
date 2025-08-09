defmodule Radar.Repo.Migrations.CreatePhotosAndInfractions do
  use Ecto.Migration

  def change do
    create table(:photos) do
      add :filename, :string, null: false
      add :file_path, :string
      add :tigris_key, :string
      add :content_type, :string
      add :file_size, :integer

      timestamps()
    end

    create table(:infractions) do
      add :photo_id, references(:photos, on_delete: :delete_all), null: false
      add :type, :string, null: false, default: "speed_ticket"
      add :datetime_taken, :naive_datetime, null: false
      add :recorded_speed, :integer, null: false
      add :authorized_speed, :integer, null: false
      add :location, :string, null: false

      timestamps()
    end

    create index(:infractions, [:photo_id])
    create index(:infractions, [:type])
    create index(:infractions, [:datetime_taken])
  end
end
