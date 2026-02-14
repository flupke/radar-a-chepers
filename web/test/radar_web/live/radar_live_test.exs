defmodule RadarWeb.RadarLiveTest do
  use RadarWeb.ConnCase
  use ExUnit.Case

  import Phoenix.LiveViewTest
  import Radar.PhotosFixtures
  import Radar.InfractionsFixtures

  alias Radar.Infractions
  alias Radar.Repo

  setup do
    # Clean up any existing data
    Repo.delete_all(Radar.Infraction)
    Repo.delete_all(Radar.Photo)

    :ok
  end

  describe "RadarLive landing page immediate display" do
    test "shows empty state when no infractions exist", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      assert html =~ "RADAR SYSTEM ACTIVE"
      assert html =~ "Waiting for infractions..."
      assert has_element?(view, "div", "📷")

      # Verify empty state in rendered content
      assert render(view) =~ "RADAR SYSTEM ACTIVE"
      assert render(view) =~ "Waiting for infractions..."
    end

    test "immediately shows most recent infraction when infractions exist", %{conn: conn} do
      # Create infractions with different timestamps - newest first
      photo1 = photo_fixture(%{"filename" => "oldest.jpg"})
      photo2 = photo_fixture(%{"filename" => "middle.jpg"})
      photo3 = photo_fixture(%{"filename" => "newest.jpg"})

      oldest_time = ~N[2024-01-15 10:00:00]
      middle_time = ~N[2024-01-15 11:00:00]
      newest_time = ~N[2024-01-15 12:00:00]

      _infraction1 =
        infraction_fixture(%{
          photo_id: photo1.id,
          datetime_taken: oldest_time,
          recorded_speed: 70,
          authorized_speed: 55,
          location: "Highway 1"
        })

      _infraction2 =
        infraction_fixture(%{
          photo_id: photo2.id,
          datetime_taken: middle_time,
          recorded_speed: 80,
          authorized_speed: 55,
          location: "Highway 2"
        })

      _infraction3 =
        infraction_fixture(%{
          photo_id: photo3.id,
          datetime_taken: newest_time,
          recorded_speed: 90,
          authorized_speed: 55,
          location: "Highway 3"
        })

      {:ok, view, html} = live(conn, "/")

      # Should show the newest infraction immediately (no delay)
      assert html =~ "90 MPH"
      assert html =~ "Highway 3"
      # Photo URL from mock S3 client
      assert html =~ "/images/seed_"
      refute html =~ "RADAR SYSTEM ACTIVE"
      # oldest should not be visible
      refute html =~ "70 MPH"
      # middle should not be visible
      refute html =~ "80 MPH"

      # Verify in rendered content
      refute render(view) =~ "RADAR SYSTEM ACTIVE"
    end

    test "displays newest infraction with complete mugshot-style overlay", %{conn: conn} do
      photo = photo_fixture(%{"filename" => "test_violation.jpg"})

      _infraction =
        infraction_fixture(%{
          photo_id: photo.id,
          datetime_taken: ~N[2024-01-15 14:30:00],
          recorded_speed: 85,
          authorized_speed: 60,
          location: "Interstate 5 Mile 100"
        })

      {:ok, _view, html} = live(conn, "/")

      # Check all overlay elements are present immediately
      assert html =~ "SPEED VIOLATION"
      assert html =~ "01/15/2024 02:30:00 PM"
      assert html =~ "RECORDED SPEED"
      assert html =~ "85 MPH"
      assert html =~ "SPEED LIMIT"
      assert html =~ "60 MPH"
      assert html =~ "VIOLATION"
      assert html =~ "+25 MPH"
      assert html =~ "LOCATION"
      assert html =~ "Interstate 5 Mile 100"
      assert html =~ "CASE TYPE"
      # Check for lowercase since template uses lowercase with uppercase CSS
      assert html =~ "speed ticket"
      # QR code is rendered as base64 data URI
      assert html =~ "data:image/svg+xml;base64,"

      # Check photo is displayed
      assert html =~ "/images/seed_"

      # Check case ID is a UUID
      assert html =~ ~r/#[0-9a-f]{8}-[0-9a-f]{4}-/
    end
  end

  describe "RadarLive cycling behavior through most recent infractions" do
    test "cycles through infractions in chronological order after timer advances", %{conn: conn} do
      # Create multiple infractions in specific order
      photo1 = photo_fixture(%{"filename" => "first.jpg"})
      photo2 = photo_fixture(%{"filename" => "second.jpg"})
      photo3 = photo_fixture(%{"filename" => "third.jpg"})

      # Create in chronological order
      _infraction1 =
        infraction_fixture(%{
          photo_id: photo1.id,
          datetime_taken: ~N[2024-01-15 10:00:00],
          recorded_speed: 70,
          location: "Location 1"
        })

      _infraction2 =
        infraction_fixture(%{
          photo_id: photo2.id,
          datetime_taken: ~N[2024-01-15 11:00:00],
          recorded_speed: 80,
          location: "Location 2"
        })

      _infraction3 =
        infraction_fixture(%{
          photo_id: photo3.id,
          datetime_taken: ~N[2024-01-15 12:00:00],
          recorded_speed: 90,
          location: "Location 3"
        })

      {:ok, view, _html} = live(conn, "/")

      # Should start with newest infraction (Location 3)
      assert render(view) =~ "90 MPH"
      assert render(view) =~ "Location 3"

      # Simulate timer advance message
      send(view.pid, :advance_infraction)

      # Should cycle to next infraction (Location 2)
      assert render(view) =~ "80 MPH"
      assert render(view) =~ "Location 2"

      # Advance again
      send(view.pid, :advance_infraction)

      # Should cycle to next infraction (Location 1)
      assert render(view) =~ "70 MPH"
      assert render(view) =~ "Location 1"

      # Advance again - should wrap back to newest
      send(view.pid, :advance_infraction)

      # Should wrap back to newest infraction (Location 3)
      assert render(view) =~ "90 MPH"
      assert render(view) =~ "Location 3"
    end

    test "correctly cycles through 5 infractions showing proper order", %{conn: conn} do
      # Create 5 infractions to test comprehensive cycling
      photos = Enum.map(1..5, fn i -> photo_fixture(%{"filename" => "photo_#{i}.jpg"}) end)

      _infractions =
        photos
        |> Enum.with_index(1)
        |> Enum.map(fn {photo, i} ->
          infraction_fixture(%{
            photo_id: photo.id,
            # Add hours
            datetime_taken: ~N[2024-01-15 10:00:00] |> NaiveDateTime.add(i * 3600),
            recorded_speed: 50 + i * 10,
            location: "Location #{i}"
          })
        end)

      {:ok, view, _html} = live(conn, "/")

      # Should start with newest (Location 5, 100 MPH)
      assert render(view) =~ "100 MPH"
      assert render(view) =~ "Location 5"

      # Cycle through all infractions and verify order
      expected_sequence = [
        {"90 MPH", "Location 4"},
        {"80 MPH", "Location 3"},
        {"70 MPH", "Location 2"},
        {"60 MPH", "Location 1"},
        # Should wrap back to newest
        {"100 MPH", "Location 5"}
      ]

      Enum.with_index(expected_sequence, 1)
      |> Enum.each(fn {{expected_speed, expected_location}, step} ->
        send(view.pid, :advance_infraction)

        rendered = render(view)
        assert rendered =~ expected_speed, "Step #{step}: Expected speed #{expected_speed}"

        assert rendered =~ expected_location,
               "Step #{step}: Expected location #{expected_location}"
      end)
    end

    test "handles advance_photo message gracefully when no infractions", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Should show empty state
      assert render(view) =~ "RADAR SYSTEM ACTIVE"

      # Send advance message - should not crash
      send(view.pid, :advance_infraction)

      # Should still show empty state
      assert render(view) =~ "RADAR SYSTEM ACTIVE"
      assert render(view) =~ "Waiting for infractions..."
    end
  end

  describe "RadarLive real-time updates with immediate display" do
    test "shows new infraction immediately when broadcast via PubSub", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      # Initially should show empty state
      assert html =~ "RADAR SYSTEM ACTIVE"

      # Create and broadcast new infraction
      photo = photo_fixture(%{"filename" => "new_violation.jpg"})

      {:ok, _infraction} =
        Infractions.create_speed_ticket(%{
          photo_id: photo.id,
          datetime_taken: ~N[2024-01-15 15:45:00],
          recorded_speed: 95,
          authorized_speed: 65,
          location: "Highway 101 Mile 50"
        })

      # The infraction should appear immediately due to PubSub
      assert render(view) =~ "95 MPH"
      assert render(view) =~ "Highway 101 Mile 50"
      refute render(view) =~ "RADAR SYSTEM ACTIVE"
    end

    test "immediately switches to newest infraction when new one arrives during cycling", %{
      conn: conn
    } do
      # Start with two infractions
      photo1 = photo_fixture(%{"filename" => "first.jpg"})
      photo2 = photo_fixture(%{"filename" => "second.jpg"})

      _infraction1 =
        infraction_fixture(%{
          photo_id: photo1.id,
          datetime_taken: ~N[2024-01-15 10:00:00],
          recorded_speed: 70,
          location: "Old Location 1"
        })

      _infraction2 =
        infraction_fixture(%{
          photo_id: photo2.id,
          datetime_taken: ~N[2024-01-15 11:00:00],
          recorded_speed: 80,
          location: "Old Location 2"
        })

      {:ok, view, _html} = live(conn, "/")

      # Should start with newest (Location 2)
      assert render(view) =~ "80 MPH"
      assert render(view) =~ "Old Location 2"

      # Advance to show first infraction
      send(view.pid, :advance_infraction)
      assert render(view) =~ "70 MPH"
      assert render(view) =~ "Old Location 1"

      # Now add a new infraction via PubSub
      photo3 = photo_fixture(%{"filename" => "newest.jpg"})

      {:ok, _new_infraction} =
        Infractions.create_speed_ticket(%{
          photo_id: photo3.id,
          datetime_taken: ~N[2024-01-15 12:00:00],
          recorded_speed: 95,
          authorized_speed: 65,
          location: "Brand New Location"
        })

      # Should immediately show the newest infraction and reset index
      assert render(view) =~ "95 MPH"
      assert render(view) =~ "Brand New Location"
    end

    test "updates to newest infraction when multiple are broadcast rapidly", %{conn: conn} do
      # Start with one infraction
      photo1 = photo_fixture(%{"filename" => "first.jpg"})

      _infraction1 =
        infraction_fixture(%{
          photo_id: photo1.id,
          datetime_taken: ~N[2024-01-15 10:00:00],
          recorded_speed: 75,
          location: "First Location"
        })

      {:ok, view, html} = live(conn, "/")
      assert html =~ "75 MPH"
      assert html =~ "First Location"

      # Add multiple newer infractions rapidly via PubSub
      photo2 = photo_fixture(%{"filename" => "second.jpg"})
      photo3 = photo_fixture(%{"filename" => "third.jpg"})

      {:ok, _infraction2} =
        Infractions.create_speed_ticket(%{
          photo_id: photo2.id,
          datetime_taken: ~N[2024-01-15 11:00:00],
          recorded_speed: 85,
          authorized_speed: 55,
          location: "Second Location"
        })

      # Should show the second infraction
      assert render(view) =~ "85 MPH"
      assert render(view) =~ "Second Location"

      {:ok, _final_infraction} =
        Infractions.create_speed_ticket(%{
          photo_id: photo3.id,
          datetime_taken: ~N[2024-01-15 12:00:00],
          recorded_speed: 105,
          authorized_speed: 55,
          location: "Final Location"
        })

      # Should immediately show the newest (final) infraction
      assert render(view) =~ "105 MPH"
      assert render(view) =~ "Final Location"
    end
  end

  describe "RadarLive assigns and state management" do
    test "correctly sets infractions_empty? flag based on data presence", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      # Should start empty
      assert render(view) =~ "RADAR SYSTEM ACTIVE"
      assert render(view) =~ "Waiting for infractions..."

      # Add an infraction
      photo = photo_fixture(%{"filename" => "test.jpg"})

      {:ok, _infraction} =
        Infractions.create_speed_ticket(%{
          photo_id: photo.id,
          datetime_taken: ~N[2024-01-15 12:00:00],
          recorded_speed: 85,
          authorized_speed: 55,
          location: "Test Location"
        })

      # Should no longer be empty
      refute render(view) =~ "RADAR SYSTEM ACTIVE"
      refute render(view) =~ "Waiting for infractions..."
      assert render(view) =~ "85 MPH"
    end

    test "maintains correct cycling behavior through multiple infractions", %{conn: conn} do
      # Create three infractions
      photos = Enum.map(1..3, fn i -> photo_fixture(%{"filename" => "photo_#{i}.jpg"}) end)

      Enum.with_index(photos, 1)
      |> Enum.each(fn {photo, i} ->
        infraction_fixture(%{
          photo_id: photo.id,
          datetime_taken: ~N[2024-01-15 10:00:00] |> NaiveDateTime.add(i * 3600),
          recorded_speed: 50 + i * 10,
          location: "Location #{i}"
        })
      end)

      {:ok, view, _html} = live(conn, "/")

      # Should start with newest (Location 3)
      assert render(view) =~ "80 MPH"
      assert render(view) =~ "Location 3"

      # Test full cycle with proper wrapping
      indices_and_advances = [
        {"70 MPH", "Location 2"},
        {"60 MPH", "Location 1"},
        {"80 MPH", "Location 3"},
        {"70 MPH", "Location 2"},
        {"60 MPH", "Location 1"},
        {"80 MPH", "Location 3"}
      ]

      Enum.each(indices_and_advances, fn {expected_speed, expected_location} ->
        send(view.pid, :advance_infraction)

        rendered = render(view)
        assert rendered =~ expected_speed, "Expected speed #{expected_speed}"
        assert rendered =~ expected_location, "Expected location #{expected_location}"
      end)
    end

    test "resets to newest infraction when new one arrives during cycling", %{conn: conn} do
      # Create initial infractions
      photos = Enum.map(1..3, fn i -> photo_fixture(%{"filename" => "initial_#{i}.jpg"}) end)

      Enum.with_index(photos, 1)
      |> Enum.each(fn {photo, i} ->
        infraction_fixture(%{
          photo_id: photo.id,
          datetime_taken: ~N[2024-01-15 10:00:00] |> NaiveDateTime.add(i * 3600),
          recorded_speed: 50 + i * 10,
          location: "Initial Location #{i}"
        })
      end)

      {:ok, view, _html} = live(conn, "/")

      # Advance to middle of cycling
      send(view.pid, :advance_infraction)
      send(view.pid, :advance_infraction)
      assert render(view) =~ "60 MPH"
      assert render(view) =~ "Initial Location 1"

      # Add new infraction
      new_photo = photo_fixture(%{"filename" => "newest.jpg"})

      {:ok, _new_infraction} =
        Infractions.create_speed_ticket(%{
          photo_id: new_photo.id,
          datetime_taken: ~N[2024-01-15 15:00:00],
          recorded_speed: 100,
          authorized_speed: 55,
          location: "Latest Location"
        })

      # Should immediately show new infraction
      assert render(view) =~ "100 MPH"
      assert render(view) =~ "Latest Location"
    end
  end
end
