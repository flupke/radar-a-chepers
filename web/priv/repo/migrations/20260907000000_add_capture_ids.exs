defmodule Radar.Repo.Migrations.AddCaptureIds do
  use Ecto.Migration

  def change do
    alter table(:photos) do
      add :capture_id, :string
      add :capture_fingerprint, :string
    end

    alter table(:infractions) do
      add :capture_id, :string
    end

    create unique_index(:photos, [:capture_id])
    create unique_index(:infractions, [:capture_id])
  end
end
