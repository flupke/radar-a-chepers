defmodule Radar.Repo.Migrations.RemoveDatetimeTaken do
  use Ecto.Migration

  def change do
    alter table(:infractions) do
      remove :datetime_taken
    end
  end
end
