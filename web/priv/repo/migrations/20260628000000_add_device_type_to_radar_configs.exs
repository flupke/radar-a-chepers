defmodule Radar.Repo.Migrations.AddDeviceTypeToRadarConfigs do
  use Ecto.Migration

  def up do
    alter table(:radar_configs) do
      add :device_type, :string, null: false, default: "rd03d"
    end

    execute """
    UPDATE radar_configs
    SET device_type = 'rd03d'
    WHERE device_type IS NULL OR device_type = ''
    """

    execute """
    INSERT INTO radar_configs (
      device_type,
      authorized_speed,
      min_dist,
      max_dist,
      trigger_cooldown,
      aperture_angle,
      capture_paused,
      inserted_at,
      updated_at
    )
    SELECT
      'ld2451',
      25,
      0,
      10000,
      1000,
      90,
      0,
      datetime('now'),
      datetime('now')
    WHERE NOT EXISTS (
      SELECT 1 FROM radar_configs WHERE device_type = 'ld2451'
    )
    """

    create unique_index(:radar_configs, [:device_type])
  end

  def down do
    drop unique_index(:radar_configs, [:device_type])

    execute "DELETE FROM radar_configs WHERE device_type = 'ld2451'"

    alter table(:radar_configs) do
      remove :device_type
    end
  end
end
