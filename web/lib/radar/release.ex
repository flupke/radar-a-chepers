defmodule Radar.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :radar

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def unseed do
    load_app()
    import Ecto.Query

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          seed_photos = from(p in Radar.Photo, where: like(p.filename, "seed_%"))
          seed_photo_ids = repo.all(from(p in seed_photos, select: p.id))

          {count_i, _} =
            repo.delete_all(from(i in Radar.Infraction, where: i.photo_id in ^seed_photo_ids))

          {count_p, _} = repo.delete_all(seed_photos)
          IO.puts("Deleted #{count_i} seed infractions and #{count_p} seed photos.")
        end)
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
