defmodule Mix.Tasks.Radar.FlySeed do
  @moduledoc "Seed the production app via the API"
  use Mix.Task

  @shortdoc "Push seed data to the Fly.io app via the API"

  @locations [
    "Interstate 5 Mile 100",
    "Highway 101 Mile 42",
    "Downtown 3rd Ave & Pine",
    "SR-520 Eastbound",
    "I-80 West Exit 12"
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    Application.ensure_all_started(:req)

    {opts, _, _} =
      OptionParser.parse(args, strict: [url: :string, api_key: :string])

    base_url = opts[:url] || raise "Missing --url"
    api_key = opts[:api_key] || raise "Missing --api-key"

    images_dir = Path.join([File.cwd!(), "priv", "static", "images"])
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    for i <- 1..5 do
      image_path = Path.join(images_dir, "seed_#{i}.jpg")
      image_data = File.read!(image_path)
      dt = NaiveDateTime.add(now, -i * 3600)
      speed = 60 + i * 5
      location = Enum.at(@locations, rem(i - 1, 5))

      infraction_json =
        Jason.encode!(%{
          datetime_taken: NaiveDateTime.to_iso8601(dt),
          recorded_speed: speed,
          authorized_speed: 55,
          location: location
        })

      Mix.shell().info("==> Uploading seed_#{i}.jpg (#{speed} MPH at #{location})...")

      case Req.post("#{base_url}/api/photos",
             headers: [{"x-api-key", api_key}],
             form_multipart: [
               photo: {image_data, filename: "seed_#{i}.jpg", content_type: "image/jpeg"},
               infraction: infraction_json
             ]
           ) do
        {:ok, %{status: status, body: body}} when status in 200..299 ->
          Mix.shell().info("    Created infraction ##{body["infraction_id"]}")

        {:ok, %{status: status, body: body}} ->
          Mix.shell().error("    Failed (#{status}): #{inspect(body)}")

        {:error, reason} ->
          Mix.shell().error("    Error: #{inspect(reason)}")
      end
    end

    Mix.shell().info("==> Done!")
  end
end
