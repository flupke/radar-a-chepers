defmodule RadarWeb.AdminLiveTest do
  use RadarWeb.ConnCase

  import Radar.InfractionsFixtures
  import Radar.PhotosFixtures

  alias Radar.Repo
  alias Radar.RadarConfigs

  setup do
    Repo.delete_all(Radar.Infraction)
    Repo.delete_all(Radar.Photo)

    :ok
  end

  test "shows radar configuration by default", %{conn: conn} do
    conn
    |> log_in_admin()
    |> visit(~p"/admin")
    |> assert_has("h1", "Admin")
    |> assert_has("a[href='/admin/infractions']", "Infractions")
    |> assert_has("h2", "Trigger Parameters")
    |> assert_has("h2", "Live Radar Data")
    |> assert_has("#radar-canvas")
  end

  test "persists radar configuration changes and restores canvas limits after reload", %{
    conn: conn
  } do
    params = %{
      "authorized_speed" => "55",
      "min_dist" => "6.5",
      "max_dist" => "12.0",
      "trigger_cooldown" => "2.5",
      "aperture_angle" => "75"
    }

    session =
      conn
      |> log_in_admin()
      |> visit(~p"/admin")
      |> unwrap(fn view ->
        view
        |> Phoenix.LiveViewTest.form("form", config: params)
        |> Phoenix.LiveViewTest.render_change()
      end)

    config = RadarConfigs.get_config!()

    assert config.authorized_speed == 55
    assert config.min_dist == 6500
    assert config.max_dist == 12_000
    assert config.trigger_cooldown == 2500
    assert config.aperture_angle == 75

    session
    |> assert_has("output", "6.5 m")
    |> assert_has("output", "12.0 m")
    |> assert_has("output", "75 degrees")

    conn
    |> log_in_admin()
    |> visit(~p"/admin")
    |> assert_has("#radar-canvas[data-radar-config]")
  end

  test "lists infractions with individual photo links and a reliable page archive", %{conn: conn} do
    old_photo = photo_fixture(%{"filename" => "old.jpg", "file_size" => 2048})
    new_photo = photo_fixture(%{"filename" => "new.jpg", "file_size" => 4096})

    old_infraction =
      infraction_fixture(%{
        photo_id: old_photo.id,
        datetime_taken: ~N[2024-01-15 10:00:00],
        location: "Highway 1"
      })

    new_infraction =
      infraction_fixture(%{
        photo_id: new_photo.id,
        datetime_taken: ~N[2024-01-15 11:00:00],
        location: "Highway 2",
        recorded_speed: 82
      })

    conn
    |> log_in_admin()
    |> visit(~p"/admin/infractions")
    |> assert_has("p", "Showing 1-2 of 2 infractions")
    |> assert_has("#infraction-#{old_infraction.id}", "Highway 1")
    |> assert_has("#infraction-#{new_infraction.id}", "Highway 2")
    |> assert_has("#infraction-#{old_infraction.id}", "old.jpg")
    |> assert_has("#infraction-#{new_infraction.id}", "new.jpg")
    |> assert_has("img[src^='/dev/photos/']")
    |> assert_has("a#download-all-photos[download='infraction-photos-page-1.zip']")
    |> assert_has("button[aria-label='Download options']")
    |> assert_has("a[download='infraction-photos-all.zip']", "Download all photos")
    |> assert_has("a[download='old.jpg']", "Download")
    |> assert_has("a[download='new.jpg']", "Download")
    |> assert_has(
      "a[href='/infractions/#{new_infraction.id}'][target='_blank'][rel='noopener noreferrer']",
      "##{short_id(new_infraction.id)}"
    )
  end

  test "sorts infractions by date, location and speed", %{conn: conn} do
    zulu_photo = photo_fixture(%{"filename" => "zulu.jpg"})
    alpha_photo = photo_fixture(%{"filename" => "alpha.jpg"})
    middle_photo = photo_fixture(%{"filename" => "middle.jpg"})

    zulu =
      infraction_fixture(%{
        photo_id: zulu_photo.id,
        datetime_taken: ~N[2024-01-15 12:00:00],
        location: "Zulu Road",
        recorded_speed: 70
      })

    alpha =
      infraction_fixture(%{
        photo_id: alpha_photo.id,
        datetime_taken: ~N[2024-01-15 11:00:00],
        location: "Alpha Road",
        recorded_speed: 90
      })

    middle =
      infraction_fixture(%{
        photo_id: middle_photo.id,
        datetime_taken: ~N[2024-01-15 10:00:00],
        location: "Middle Road",
        recorded_speed: 60
      })

    session =
      conn
      |> log_in_admin()
      |> visit(~p"/admin/infractions")
      |> assert_has("tbody tr:first-child#infraction-#{zulu.id}", "Zulu Road")

    session
    |> click_link("Location")
    |> assert_path(~p"/admin/infractions",
      query_params: %{"page" => "1", "sort" => "location", "dir" => "asc"}
    )
    |> assert_has("tbody tr:first-child#infraction-#{alpha.id}", "Alpha Road")
    |> click_link("Location")
    |> assert_path(~p"/admin/infractions",
      query_params: %{"page" => "1", "sort" => "location", "dir" => "desc"}
    )
    |> assert_has("tbody tr:first-child#infraction-#{zulu.id}", "Zulu Road")
    |> click_link("Speed")
    |> assert_path(~p"/admin/infractions",
      query_params: %{"page" => "1", "sort" => "speed", "dir" => "desc"}
    )
    |> assert_has("tbody tr:first-child#infraction-#{alpha.id}", "Alpha Road")
    |> click_link("Date")
    |> assert_path(~p"/admin/infractions",
      query_params: %{"page" => "1", "sort" => "date", "dir" => "desc"}
    )
    |> assert_has("tbody tr:first-child#infraction-#{zulu.id}", "Zulu Road")
    |> refute_has("tbody tr:first-child#infraction-#{middle.id}")
  end

  test "redirects the legacy infractions tab URL to the infractions page", %{conn: conn} do
    conn
    |> log_in_admin()
    |> visit(~p"/admin?tab=infractions&page=2")
    |> assert_path(~p"/admin/infractions", query_params: %{"page" => "2"})
  end

  test "downloads the current page photos as a zip archive", %{conn: conn} do
    old_photo = photo_fixture(%{"filename" => "old.jpg", "data" => "old data"})
    new_photo = photo_fixture(%{"filename" => "new.jpg", "data" => "new data"})

    infraction_fixture(%{
      photo_id: old_photo.id,
      datetime_taken: ~N[2024-01-15 10:00:00],
      location: "Highway 1"
    })

    infraction_fixture(%{
      photo_id: new_photo.id,
      datetime_taken: ~N[2024-01-15 11:00:00],
      location: "Highway 2"
    })

    conn = get(log_in_admin(conn), ~p"/admin/infractions/photos.zip?page=1&sort=date&dir=desc")

    assert get_resp_header(conn, "content-type") == ["application/zip; charset=utf-8"]
    assert [content_disposition] = get_resp_header(conn, "content-disposition")
    assert content_disposition =~ ~s(attachment; filename="infraction-photos-page-1.zip")

    assert {:ok, files} = :zip.extract(response(conn, 200), [:memory])
    assert length(files) == 2

    assert Enum.any?(files, fn {name, data} ->
             to_string(name) =~ "old.jpg" and data == "old data"
           end)

    assert Enum.any?(files, fn {name, data} ->
             to_string(name) =~ "new.jpg" and data == "new data"
           end)
  end

  test "downloads all photos as a streamed zip archive", %{conn: conn} do
    old_photo = photo_fixture(%{"filename" => "old.jpg", "data" => "old data"})
    new_photo = photo_fixture(%{"filename" => "new.jpg", "data" => "new data"})

    infraction_fixture(%{
      photo_id: old_photo.id,
      datetime_taken: ~N[2024-01-15 10:00:00],
      location: "Highway 1"
    })

    infraction_fixture(%{
      photo_id: new_photo.id,
      datetime_taken: ~N[2024-01-15 11:00:00],
      location: "Highway 2"
    })

    conn = get(log_in_admin(conn), ~p"/admin/infractions/photos.zip?scope=all")

    assert get_resp_header(conn, "content-type") == ["application/zip; charset=utf-8"]
    assert [content_disposition] = get_resp_header(conn, "content-disposition")
    assert content_disposition =~ ~s(attachment; filename="infraction-photos-all.zip")

    assert {:ok, files} = :zip.extract(response(conn, 200), [:memory])
    assert length(files) == 2

    assert Enum.any?(files, fn {name, data} ->
             to_string(name) =~ "old.jpg" and data == "old data"
           end)

    assert Enum.any?(files, fn {name, data} ->
             to_string(name) =~ "new.jpg" and data == "new data"
           end)
  end

  test "updates the infractions page when a new infraction is created", %{conn: conn} do
    session =
      conn
      |> log_in_admin()
      |> visit(~p"/admin/infractions")
      |> assert_has("p", "No infractions yet.")

    photo = photo_fixture(%{"filename" => "fresh.jpg"})

    infraction =
      infraction_fixture(%{
        photo_id: photo.id,
        datetime_taken: ~N[2024-01-15 12:00:00],
        location: "Fresh Road"
      })

    session
    |> assert_has("#infraction-#{infraction.id}", "fresh.jpg")
    |> assert_has("#infraction-#{infraction.id}", "Fresh Road")
    |> assert_has("p", "Showing 1-1 of 1 infraction")
  end

  defp log_in_admin(conn) do
    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(:admin_email, "admin@test.com")
    |> Plug.Conn.put_session(:admin_name, "Admin")
  end

  defp short_id(id) do
    id
    |> to_string()
    |> String.slice(0, 8)
  end
end
