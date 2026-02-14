alias Radar.{Repo, Infractions}

locations = [
  "Interstate 5 Mile 100",
  "Highway 101 Mile 42",
  "Downtown 3rd Ave & Pine",
  "SR-520 Eastbound",
  "I-80 West Exit 12"
]

existing = Repo.aggregate(Radar.Infraction, :count, :id)

if existing > 0 do
  IO.puts("Dev seeds: infractions already present (#{existing}), skipping seeding.")
else
  IO.puts("Dev seeds: inserting sample photos and infractions...")

  now = DateTime.utc_now() |> DateTime.to_naive() |> NaiveDateTime.truncate(:second)

  1..5
  |> Enum.each(fn i ->
    {:ok, photo} =
      %Radar.Photo{}
      |> Radar.Photo.changeset(%{
        filename: "seed_#{i}.jpg",
        tigris_key: "seed_#{i}",
        content_type: "image/jpeg",
        file_size: 17_000
      })
      |> Repo.insert()

    dt = NaiveDateTime.add(now, -i * 3600)

    {:ok, _infraction} =
      Infractions.create_speed_ticket(%{
        photo_id: photo.id,
        datetime_taken: dt,
        recorded_speed: 60 + i * 5,
        authorized_speed: 55,
        location: Enum.at(locations, rem(i - 1, length(locations)))
      })
  end)

  IO.puts("Dev seeds: done.")
end
