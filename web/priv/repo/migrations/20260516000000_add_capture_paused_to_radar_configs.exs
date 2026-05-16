defmodule Radar.Repo.Migrations.AddCapturePausedToRadarConfigs do
  use Ecto.Migration

  def change do
    alter table(:radar_configs) do
      add :capture_paused, :boolean, null: false, default: false
    end
  end
end
