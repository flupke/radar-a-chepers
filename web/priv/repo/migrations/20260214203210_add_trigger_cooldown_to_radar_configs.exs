defmodule Radar.Repo.Migrations.AddTriggerCooldownToRadarConfigs do
  use Ecto.Migration

  def change do
    alter table(:radar_configs) do
      add :trigger_cooldown, :integer, null: false, default: 1000
    end
  end
end
