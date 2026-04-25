defmodule Radar.Repo.Migrations.AddApertureAngleToRadarConfigs do
  use Ecto.Migration

  def change do
    alter table(:radar_configs) do
      add :aperture_angle, :integer, null: false, default: 90
    end
  end
end
