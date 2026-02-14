defmodule Radar.Repo.Migrations.CreateRadarConfigs do
  use Ecto.Migration

  def change do
    create table(:radar_configs) do
      add :authorized_speed, :integer, null: false, default: 25
      add :min_dist, :integer, null: false, default: 0
      add :max_dist, :integer, null: false, default: 10_000

      timestamps()
    end

    execute "INSERT INTO radar_configs (authorized_speed, min_dist, max_dist, inserted_at, updated_at) VALUES (25, 0, 10000, datetime('now'), datetime('now'))",
            "DELETE FROM radar_configs"
  end
end
