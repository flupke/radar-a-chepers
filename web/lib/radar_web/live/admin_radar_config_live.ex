defmodule RadarWeb.AdminRadarConfigLive do
  use RadarWeb, :live_view

  import RadarWeb.AdminComponents

  alias Radar.{Infractions, RadarConfigs, RadarData}
  alias Phoenix.LiveView.ColocatedHook
  alias RadarWeb.ActiveRadar
  alias RadarWeb.Presence

  @max_uploader_logs 100
  @uploader_debug_topic "uploader_debug"
  @default_device_type "rd03d"

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Radar.PubSub, "radar_config")
      Phoenix.PubSub.subscribe(Radar.PubSub, "radar_data")
      Phoenix.PubSub.subscribe(Radar.PubSub, "infractions")
      Phoenix.PubSub.subscribe(Radar.PubSub, @uploader_debug_topic)
      Phoenix.PubSub.subscribe(Radar.PubSub, Presence.uploader_topic())
    end

    active_radar = ActiveRadar.current()
    selected_device_type = selected_device_type(active_radar)
    config = RadarConfigs.get_config!(selected_device_type)
    debug_device_type = debug_device_type(active_radar, selected_device_type)
    debug_config = RadarConfigs.get_config!(debug_device_type)
    last_target = last_known_target(active_radar)

    socket =
      socket
      |> assign(:supported_device_types, RadarConfigs.supported_device_types())
      |> assign(:selected_device_type, selected_device_type)
      |> assign(:active_radar, active_radar)
      |> assign(:config, config)
      |> assign(:debug_device_type, debug_device_type)
      |> assign(:debug_config, debug_config)
      |> assign(:form, config_to_form(config))
      |> assign(:infraction_count, Infractions.count_infractions())
      |> assign(:uploader_debug, %{connected: Presence.uploader_connected?(), logs: []})
      |> assign(:last_target, last_target)
      |> push_debug_config_event()

    {:ok, socket}
  end

  def handle_params(%{"tab" => "infractions"} = params, _uri, socket) do
    {:noreply, push_navigate(socket, to: legacy_infractions_path(params))}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <.admin_shell
      active="config"
      current_admin={@current_admin}
      infraction_count={@infraction_count}
    >
      <div class="max-w-2xl mx-auto space-y-8">
        <div class="card bg-base-200 shadow-lg">
          <div class="card-body">
            <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <h2 class="card-title">Trigger Parameters</h2>
                <p class="text-sm opacity-70">
                  Camera capture is {capture_status(@config)}.
                </p>
              </div>
              <button
                type="button"
                phx-click="toggle_capture"
                class={capture_button_class(@config)}
                aria-pressed={to_string(@config.capture_paused)}
              >
                <.icon name={capture_button_icon(@config)} class="size-4" />
                {capture_button_label(@config)}
              </button>
            </div>

            <div class="grid gap-3 rounded-lg bg-base-300 p-3 text-sm sm:grid-cols-[1fr_auto] sm:items-center">
              <div id="active-device-status">
                <span class="opacity-70">Active device</span>
                <div :if={@active_radar} class="mt-1 flex flex-wrap items-center gap-2">
                  <span class="font-mono">{device_label(@active_radar.device_type)}</span>
                  <span class={test_mode_badge_class(@active_radar.test_mode)}>
                    {test_mode_label(@active_radar.test_mode)}
                  </span>
                </div>
                <div :if={!@active_radar} class="mt-1 font-mono">No device connected</div>
              </div>
              <div id="device-config-selector" class="flex flex-wrap gap-2">
                <button
                  :for={device_type <- @supported_device_types}
                  type="button"
                  phx-click="select_device"
                  phx-value-device={device_type}
                  class={device_button_class(device_type, @selected_device_type, @active_radar)}
                >
                  {device_label(device_type)}
                  <span
                    :if={active_device?(device_type, @active_radar)}
                    class="badge badge-success badge-sm"
                  >
                    active
                  </span>
                </button>
              </div>
            </div>

            <.form for={@form} phx-change="update_config" class="space-y-5">
              <.slider_input
                field={@form[:authorized_speed]}
                label="Authorized Speed (km/h)"
                min="1"
                max="200"
                step="1"
                unit="km/h"
              />
              <.slider_input
                field={@form[:min_dist]}
                label="Min Distance (meters)"
                min="0"
                max={@form[:max_dist].value}
                step="0.1"
                unit="m"
              />
              <.slider_input
                field={@form[:max_dist]}
                label="Max Distance (meters)"
                min={@form[:min_dist].value}
                max="15"
                step="0.1"
                unit="m"
              />
              <.slider_input
                field={@form[:trigger_cooldown]}
                label="Trigger Cooldown (seconds)"
                min="0"
                max="30"
                step="0.1"
                unit="s"
              />
              <.slider_input
                field={@form[:aperture_angle]}
                label="Aperture Angle"
                min="1"
                max="180"
                step="1"
                unit="degrees"
              />
            </.form>
          </div>
        </div>

        <div class="card bg-base-200 shadow-lg">
          <div class="card-body">
            <h2 class="card-title">Live Radar Data</h2>
            <canvas
              id="radar-canvas"
              phx-hook=".RadarCanvas"
              phx-update="ignore"
              data-radar-config={
                Jason.encode!(RadarConfigs.config_payload(@debug_device_type, @debug_config))
              }
              width="600"
              height="400"
              class="w-full rounded-lg"
            />
            <script :type={ColocatedHook} name=".RadarCanvas">
              export default {
                mounted() {
                  const canvas = this.el;
                  const ctx = canvas.getContext("2d");
                  ctx.fillStyle = "#191e24";
                  ctx.fillRect(0, 0, canvas.width, canvas.height);

                  const dots = [];
                  let cfg = JSON.parse(canvas.dataset.radarConfig || "null");
                  const FADE_MS = 4000;

                  this.handleEvent("radar_point", (data) => {
                    dots.push({ ...data, time: performance.now() });
                  });

                  this.handleEvent("radar_config", (data) => {
                    cfg = data;
                  });

                  this._interval = setInterval(() => {
                    const now = performance.now();
                    const w = canvas.width;
                    const h = canvas.height;
                    const viewRange = Math.max(cfg?.max_dist || 12000, 12000);
                    const scale = h / viewRange;

                    while (dots.length > 0 && now - dots[0].time > FADE_MS) dots.shift();

                    ctx.fillStyle = "#191e24";
                    ctx.fillRect(0, 0, w, h);

                    if (cfg) {
                      const cx = w / 2;
                      const cy = h;
                      const halfAngle = (cfg.aperture_angle || 180) * Math.PI / 360;
                      const boundaryLength = viewRange;
                      ctx.setLineDash([6, 6]);
                      ctx.lineWidth = 2;
                      ctx.strokeStyle = "rgba(251, 191, 36, 0.65)";

                      ctx.beginPath();
                      ctx.arc(cx, cy, cfg.min_dist * scale, Math.PI, 0);
                      ctx.stroke();

                      ctx.beginPath();
                      ctx.arc(cx, cy, cfg.max_dist * scale, Math.PI, 0);
                      ctx.stroke();

                      for (const angle of [-halfAngle, halfAngle]) {
                        ctx.beginPath();
                        ctx.moveTo(cx, cy);
                        ctx.lineTo(
                          cx + Math.sin(angle) * boundaryLength * scale,
                          cy - Math.cos(angle) * boundaryLength * scale
                        );
                        ctx.stroke();
                      }

                      ctx.setLineDash([]);
                    }

                    for (const dot of dots) {
                      const age = now - dot.time;
                      const opacity = 1 - age / FADE_MS;
                      const px = w / 2 + dot.x * scale;
                      const py = h - dot.y * scale;
                      const angle = Math.abs(Math.atan2(dot.x, dot.y) * 180 / Math.PI);
                      const inAperture = !cfg || angle <= (cfg.aperture_angle || 180) / 2;
                      const inRange = !cfg || (cfg.min_dist <= dot.distance && dot.distance <= cfg.max_dist);
                      const active = inAperture && inRange;

                      const ratio = cfg && cfg.authorized_speed > 0
                        ? Math.min(dot.speed / (cfg.authorized_speed * 2), 1)
                        : 0.5;
                      const hue = 120 * (1 - ratio);
                      const radius = dot.triggered || dot.suspicious_speed ? 8 : 7;

                      ctx.beginPath();
                      ctx.arc(px, py, radius, 0, Math.PI * 2);
                      ctx.fillStyle = active
                        ? `hsla(${hue}, 90%, 55%, ${Math.max(opacity, 0.35)})`
                        : `hsla(205, 90%, 70%, ${Math.max(opacity * 0.85, 0.25)})`;
                      ctx.fill();
                      ctx.lineWidth = active ? 2 : 1;
                      ctx.strokeStyle = active
                        ? `hsla(${hue}, 90%, 85%, ${Math.max(opacity, 0.45)})`
                        : `hsla(205, 90%, 90%, ${Math.max(opacity * 0.75, 0.25)})`;
                      ctx.stroke();

                      if (dot.triggered || dot.suspicious_speed) {
                        ctx.beginPath();
                        ctx.arc(px, py, 14, 0, Math.PI * 2);
                        ctx.strokeStyle = dot.suspicious_speed
                          ? `hsla(290, 90%, 70%, ${opacity})`
                          : `hsla(${hue}, 90%, 55%, ${opacity})`;
                        ctx.lineWidth = 2;
                        ctx.stroke();
                      }
                    }
                  }, 16);
                },
                destroyed() {
                  clearInterval(this._interval);
                }
              }
            </script>
            <div id="last-target" class="mt-4 rounded-lg bg-base-300 p-3 text-sm">
              <p :if={!@last_target} class="opacity-70">No targets yet.</p>
              <div :if={@last_target} class="grid gap-3 lg:grid-cols-2">
                <div class="grid grid-cols-2 gap-x-4 gap-y-1">
                  <span class="opacity-70">Device</span>
                  <span class="font-mono">{device_label(@last_target.device_type)}</span>
                  <span class="opacity-70">Mode</span>
                  <span class="font-mono">{test_mode_label(@last_target.test_mode)}</span>
                  <span class="opacity-70">Speed</span>
                  <span class="font-mono">
                    {@last_target.speed} km/h ({@last_target.raw_speed_cm_s} cm/s)
                  </span>
                  <span class="opacity-70">Distance</span>
                  <span class="font-mono">{format_mm_as_m(@last_target.distance)}</span>
                  <span class="opacity-70">Angle</span>
                  <span class="font-mono">{format_degrees(@last_target.angle)}</span>
                  <span class="opacity-70">Position</span>
                  <span class="font-mono">
                    x {format_mm_as_m(@last_target.x)}, y {format_mm_as_m(@last_target.y)}
                  </span>
                </div>
                <div class="grid grid-cols-2 gap-x-4 gap-y-1">
                  <span class="opacity-70">In range</span>
                  <span class={debug_bool_class(@last_target.in_range)}>
                    {yes_no(@last_target.in_range)}
                  </span>
                  <span class="opacity-70">In aperture</span>
                  <span class={debug_bool_class(@last_target.in_aperture)}>
                    {yes_no(@last_target.in_aperture)}
                  </span>
                  <span class="opacity-70">Over speed</span>
                  <span class={debug_bool_class(@last_target.over_speed)}>
                    {yes_no(@last_target.over_speed)}
                  </span>
                  <span class="opacity-70">{target_diagnostic_label(@last_target)}</span>
                  <span class={target_diagnostic_class(@last_target)}>
                    {target_diagnostic_value(@last_target)}
                  </span>
                  <span class="opacity-70">Cooldown</span>
                  <span class={debug_bool_class(@last_target.cooldown_elapsed)}>
                    {yes_no(@last_target.cooldown_elapsed)}
                  </span>
                  <span class="opacity-70">Capture paused</span>
                  <span class={debug_bool_class(!@last_target.capture_paused)}>
                    {yes_no(@last_target.capture_paused)}
                  </span>
                  <span class="opacity-70">Capture busy</span>
                  <span class={debug_bool_class(!@last_target.capture_in_progress)}>
                    {yes_no(@last_target.capture_in_progress)}
                  </span>
                  <span class="opacity-70">Would capture</span>
                  <span class={debug_bool_class(@last_target.would_trigger)}>
                    {yes_no(@last_target.would_trigger)}
                  </span>
                  <span class="opacity-70">Captured</span>
                  <span class={debug_bool_class(@last_target.triggered)}>
                    {yes_no(@last_target.triggered)}
                  </span>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div class="card bg-base-200 shadow-lg">
          <div class="card-body gap-4">
            <div class="flex items-center justify-between gap-4">
              <h2 class="card-title">Uploader Status</h2>
              <div id="uploader-connected" class="flex items-center gap-2 text-sm">
                <span class="opacity-70">Uploader connected here</span>
                <span class={uploader_status_class(@uploader_debug.connected)}>
                  {yes_no(@uploader_debug.connected)}
                </span>
              </div>
            </div>
            <div
              id="uploader-device"
              class="grid gap-2 rounded-lg bg-base-300 p-3 text-sm sm:grid-cols-2"
            >
              <div>
                <span class="opacity-70">Device</span>
                <div class="font-mono">
                  {if @active_radar, do: device_label(@active_radar.device_type), else: "--"}
                </div>
              </div>
              <div>
                <span class="opacity-70">Mode</span>
                <div class="font-mono">
                  {if @active_radar, do: test_mode_label(@active_radar.test_mode), else: "--"}
                </div>
              </div>
            </div>

            <div
              id="uploader-logs"
              phx-hook=".UploaderLogs"
              data-last-log-id={last_log_id(@uploader_debug.logs)}
              class="max-h-72 overflow-y-auto rounded-lg bg-base-300 p-3 font-mono text-xs leading-relaxed"
            >
              <p :if={@uploader_debug.logs == []} class="opacity-70">No uploader logs yet.</p>
              <div
                :for={log <- @uploader_debug.logs}
                id={"uploader-log-#{log.id}"}
                class="grid grid-cols-[4.5rem_4.5rem_1fr] gap-2 border-b border-base-content/10 py-1 last:border-b-0"
              >
                <span class="opacity-60">{format_log_time(log.at)}</span>
                <span class="opacity-70">{format_log_level(log.level)}</span>
                <span class="break-words">{log.message}</span>
              </div>
            </div>
            <script :type={ColocatedHook} name=".UploaderLogs">
              export default {
                mounted() {
                  this.lastLogId = this.el.dataset.lastLogId;
                  this.scrollToBottom();
                },
                updated() {
                  const nextLogId = this.el.dataset.lastLogId;
                  if (nextLogId !== this.lastLogId) {
                    this.lastLogId = nextLogId;
                    this.scrollToBottom();
                  }
                },
                scrollToBottom() {
                  requestAnimationFrame(() => {
                    this.el.scrollTop = this.el.scrollHeight;
                  });
                }
              }
            </script>
          </div>
        </div>
      </div>
    </.admin_shell>
    """
  end

  def handle_event("select_device", %{"device" => device_type}, socket) do
    if device_type in socket.assigns.supported_device_types do
      config = RadarConfigs.get_config!(device_type)

      {:noreply,
       socket
       |> assign(:selected_device_type, device_type)
       |> assign(:config, config)
       |> assign(:form, config_to_form(config))
       |> maybe_follow_selected_debug_config(config)
       |> push_debug_config_event()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_config", %{"config" => params}, socket) do
    db_params = form_params_to_db(params)
    device_type = socket.assigns.selected_device_type

    case RadarConfigs.update_config(device_type, db_params) do
      {:ok, config} ->
        {:noreply,
         socket
         |> assign(:config, config)
         |> assign(:form, config_to_form(config))
         |> maybe_assign_debug_config(config)
         |> push_debug_config_event()}

      {:error, _changeset} ->
        {:noreply, assign(socket, :form, to_form(params, as: :config))}
    end
  end

  def handle_event("toggle_capture", _params, socket) do
    device_type = socket.assigns.selected_device_type

    case RadarConfigs.update_config(device_type, %{
           capture_paused: !socket.assigns.config.capture_paused
         }) do
      {:ok, config} ->
        {:noreply,
         socket
         |> assign(:config, config)
         |> assign(:form, config_to_form(config))
         |> maybe_assign_debug_config(config)
         |> push_debug_config_event()}

      {:error, _changeset} ->
        {:noreply, socket}
    end
  end

  def handle_info({:config_updated, %{device_type: device_type} = config}, socket) do
    socket =
      if device_type == socket.assigns.selected_device_type do
        socket
        |> assign(:config, config)
        |> assign(:form, config_to_form(config))
      else
        socket
      end

    socket =
      if device_type == socket.assigns.debug_device_type do
        socket
        |> assign(:debug_config, config)
        |> push_debug_config_event()
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info({:config_updated, _config}, socket), do: {:noreply, socket}

  def handle_info({:new_infraction, _infraction}, socket) do
    {:noreply, assign(socket, :infraction_count, Infractions.count_infractions())}
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "presence_diff",
          topic: topic,
          payload: %{joins: joins, leaves: leaves}
        },
        socket
      ) do
    if topic == Presence.uploader_topic() do
      connected =
        cond do
          Map.has_key?(joins, Presence.uploader_key()) ->
            true

          Map.has_key?(leaves, Presence.uploader_key()) ->
            Presence.uploader_connected?()

          true ->
            socket.assigns.uploader_debug.connected
        end

      {:noreply,
       socket
       |> update(:uploader_debug, &%{&1 | connected: connected})
       |> refresh_active_radar()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:uploader_log, log}, socket) do
    {:noreply, update(socket, :uploader_debug, &append_uploader_log(&1, log))}
  end

  def handle_info({:target_data, data}, socket) do
    active_radar = ActiveRadar.current()
    target = normalize_target_data(data, active_radar)

    socket =
      if socket.assigns.uploader_debug.connected do
        socket
      else
        update(socket, :uploader_debug, &%{&1 | connected: true})
      end

    {:noreply,
     socket
     |> sync_debug_device(active_radar)
     |> assign(:last_target, target)
     |> push_event(
       "radar_point",
       Map.take(target, [:x, :y, :speed, :distance, :triggered, :suspicious_speed])
     )}
  end

  defp legacy_infractions_path(params) do
    case parse_page(params["page"]) do
      1 -> ~p"/admin/infractions"
      page -> ~p"/admin/infractions?page=#{page}"
    end
  end

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {page, _rest} when page > 0 -> page
      _ -> 1
    end
  end

  defp parse_page(_page), do: 1

  defp selected_device_type(%{device_type: device_type}), do: device_type
  defp selected_device_type(_active_radar), do: @default_device_type

  defp debug_device_type(%{device_type: device_type}, _selected_device_type), do: device_type
  defp debug_device_type(_active_radar, selected_device_type), do: selected_device_type

  defp config_to_form(config) do
    to_form(
      %{
        "authorized_speed" => config.authorized_speed,
        "min_dist" => config.min_dist / 1000,
        "max_dist" => config.max_dist / 1000,
        "trigger_cooldown" => config.trigger_cooldown / 1000,
        "aperture_angle" => config.aperture_angle
      },
      as: :config
    )
  end

  defp form_params_to_db(params) do
    min_dist_m = parse_float(params["min_dist"])
    max_dist_m = parse_float(params["max_dist"])
    cooldown_s = parse_float(params["trigger_cooldown"])

    %{
      "authorized_speed" => params["authorized_speed"],
      "min_dist" => round(min_dist_m * 1000),
      "max_dist" => round(max_dist_m * 1000),
      "trigger_cooldown" => round(cooldown_s * 1000),
      "aperture_angle" => params["aperture_angle"]
    }
  end

  defp active_device?(device_type, %{device_type: device_type}), do: true
  defp active_device?(_device_type, _active_radar), do: false

  defp device_label("rd03d"), do: "RD03-D"
  defp device_label("ld2451"), do: "LD2451"
  defp device_label(device_type), do: String.upcase(device_type)

  defp device_button_class(device_type, selected_device_type, active_radar) do
    selected? = device_type == selected_device_type
    active? = active_device?(device_type, active_radar)

    [
      "btn btn-sm",
      selected? && "btn-primary",
      !selected? && active? && "btn-success btn-outline",
      !selected? && !active? && "btn-ghost"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp test_mode_label(true), do: "Test mode"
  defp test_mode_label(false), do: "Live hardware"
  defp test_mode_label(_test_mode), do: "--"

  defp test_mode_badge_class(true), do: "badge badge-warning"
  defp test_mode_badge_class(false), do: "badge badge-info"

  defp capture_status(%{capture_paused: true}), do: "paused"
  defp capture_status(_config), do: "active"

  defp capture_button_label(%{capture_paused: true}), do: "Resume radar"
  defp capture_button_label(_config), do: "Pause radar"

  defp capture_button_icon(%{capture_paused: true}), do: "hero-play"
  defp capture_button_icon(_config), do: "hero-pause"

  defp capture_button_class(%{capture_paused: true}) do
    "btn btn-success shrink-0"
  end

  defp capture_button_class(_config) do
    "btn btn-warning shrink-0"
  end

  defp yes_no(true), do: "Yes"
  defp yes_no(false), do: "No"

  defp debug_bool_class(true), do: "font-mono text-success"
  defp debug_bool_class(false), do: "font-mono text-error"

  defp target_diagnostic_label(%{device_type: "rd03d"}), do: "Speed sentinel"
  defp target_diagnostic_label(%{device_type: "ld2451"}), do: "Radar diagnostic"
  defp target_diagnostic_label(_target), do: "Radar diagnostic"

  defp target_diagnostic_value(%{device_type: "rd03d", suspicious_speed: true}), do: "Detected"
  defp target_diagnostic_value(%{device_type: "rd03d"}), do: "Clear"
  defp target_diagnostic_value(%{suspicious_speed: true}), do: "Review target"
  defp target_diagnostic_value(_target), do: "Normal"

  defp target_diagnostic_class(%{suspicious_speed: suspicious_speed}),
    do: debug_bool_class(!suspicious_speed)

  defp uploader_status_class(true), do: "badge badge-success"
  defp uploader_status_class(false), do: "badge badge-error"

  defp format_log_time(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M:%S")
  defp format_log_time(_at), do: "--:--:--"

  defp format_log_level(level) when is_binary(level), do: String.upcase(level)
  defp format_log_level(level), do: level |> inspect() |> String.upcase()

  defp last_log_id([]), do: ""
  defp last_log_id(logs), do: logs |> List.last() |> Map.fetch!(:id)

  defp format_mm_as_m(value) when is_number(value) do
    "#{Float.round(value / 1000, 2)} m"
  end

  defp format_mm_as_m(_value), do: "--"

  defp format_degrees(value) when is_number(value) do
    "#{Float.round(value, 1)} deg"
  end

  defp format_degrees(_value), do: "--"

  defp normalize_target_data(data, active_radar) do
    %{
      device_type: target_text(data, "device_type", active_device_type(active_radar)),
      test_mode: target_test_mode(data, active_radar),
      raw_speed_cm_s: target_number(data, "raw_speed_cm_s", 0),
      speed: target_number(data, "speed", 0),
      suspicious_speed: target_bool(data, "suspicious_speed"),
      x: target_number(data, "x", 0),
      y: target_number(data, "y", 0),
      distance: target_number(data, "distance", 0.0),
      angle: target_number(data, "angle", 0.0),
      in_range: target_bool(data, "in_range"),
      in_aperture: target_bool(data, "in_aperture"),
      over_speed: target_bool(data, "over_speed"),
      cooldown_elapsed: target_bool(data, "cooldown_elapsed"),
      capture_paused: target_bool(data, "capture_paused"),
      capture_in_progress: target_bool(data, "capture_in_progress"),
      would_trigger: target_bool(data, "would_trigger"),
      triggered: target_bool(data, "triggered")
    }
  end

  defp last_known_target(active_radar) do
    case RadarData.last_target() do
      nil -> nil
      target -> normalize_target_data(target, active_radar)
    end
  end

  defp target_number(data, key, default) do
    case target_value(data, key, default) do
      value when is_number(value) -> value
      _value -> default
    end
  end

  defp target_bool(data, key) do
    case target_bool_value(data, key) do
      {:ok, value} -> value
      :error -> false
    end
  end

  defp target_test_mode(data, active_radar) do
    case target_bool_value(data, "test_mode") do
      {:ok, value} -> value
      :error -> active_test_mode(active_radar)
    end
  end

  defp target_text(data, key, default) do
    case target_value(data, key, default) do
      value when is_binary(value) -> value
      _value -> default
    end
  end

  defp target_bool_value(data, key) do
    case target_lookup(data, key) do
      {:ok, true} -> {:ok, true}
      {:ok, _value} -> {:ok, false}
      :error -> :error
    end
  end

  defp target_value(data, key, default) do
    case target_lookup(data, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp target_lookup(data, key) do
    atom_key = existing_atom_key(key)

    cond do
      Map.has_key?(data, key) ->
        {:ok, Map.fetch!(data, key)}

      atom_key && Map.has_key?(data, atom_key) ->
        {:ok, Map.fetch!(data, atom_key)}

      true ->
        :error
    end
  end

  defp existing_atom_key(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp active_device_type(%{device_type: device_type}), do: device_type
  defp active_device_type(_active_radar), do: @default_device_type

  defp active_test_mode(%{test_mode: test_mode}) when is_boolean(test_mode), do: test_mode
  defp active_test_mode(_active_radar), do: nil

  defp append_uploader_log(debug, log) do
    logs =
      debug.logs
      |> Kernel.++([normalize_uploader_log(log)])
      |> Enum.take(-@max_uploader_logs)

    %{debug | connected: true, logs: logs}
  end

  defp normalize_uploader_log(log) when is_map(log) do
    %{
      id: Map.get(log, :id, System.unique_integer([:positive])),
      at: Map.get(log, :at, DateTime.utc_now() |> DateTime.truncate(:second)),
      level: Map.get(log, :level, "info"),
      message: Map.get(log, :message, inspect(log))
    }
  end

  defp normalize_uploader_log(log) do
    %{
      id: System.unique_integer([:positive]),
      at: DateTime.utc_now() |> DateTime.truncate(:second),
      level: "info",
      message: inspect(log)
    }
  end

  defp refresh_active_radar(socket) do
    active_radar = ActiveRadar.current()

    sync_debug_device(socket, active_radar)
  end

  defp sync_debug_device(socket, active_radar) do
    debug_device_type = debug_device_type(active_radar, socket.assigns.selected_device_type)

    socket = assign(socket, :active_radar, active_radar)

    if debug_device_type == socket.assigns.debug_device_type do
      socket
    else
      socket
      |> assign(:debug_device_type, debug_device_type)
      |> assign(:debug_config, RadarConfigs.get_config!(debug_device_type))
      |> push_debug_config_event()
    end
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :unit, :string, required: true
  attr :min, :string, required: true
  attr :max, :string, required: true
  attr :step, :string, required: true

  defp slider_input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@field.id} class="label mb-1">
        <span>{@label}</span>
        <output class="font-mono text-sm">
          {@field.value} {@unit}
        </output>
      </label>
      <input
        type="range"
        id={@field.id}
        name={@field.name}
        value={@field.value}
        min={@min}
        max={@max}
        step={@step}
        class="range range-primary w-full"
      />
    </div>
    """
  end

  defp maybe_assign_debug_config(socket, %{device_type: device_type} = config) do
    if device_type == socket.assigns.debug_device_type do
      assign(socket, :debug_config, config)
    else
      socket
    end
  end

  defp maybe_follow_selected_debug_config(socket, config) do
    if socket.assigns.active_radar do
      socket
    else
      socket
      |> assign(:debug_device_type, socket.assigns.selected_device_type)
      |> assign(:debug_config, config)
    end
  end

  defp push_debug_config_event(socket) do
    push_event(
      socket,
      "radar_config",
      RadarConfigs.config_payload(socket.assigns.debug_device_type, socket.assigns.debug_config)
    )
  end

  defp parse_float(val) when is_binary(val) do
    case Float.parse(val) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp parse_float(val) when is_number(val), do: val / 1
  defp parse_float(_), do: 0.0
end
