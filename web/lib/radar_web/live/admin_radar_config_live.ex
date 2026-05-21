defmodule RadarWeb.AdminRadarConfigLive do
  use RadarWeb, :live_view

  import RadarWeb.AdminComponents

  alias Radar.{Infractions, RadarConfigs}
  alias Phoenix.LiveView.ColocatedHook
  alias RadarWeb.Presence

  @max_uploader_logs 100
  @uploader_debug_topic "uploader_debug"

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Radar.PubSub, "radar_config")
      Phoenix.PubSub.subscribe(Radar.PubSub, "radar_data")
      Phoenix.PubSub.subscribe(Radar.PubSub, "infractions")
      Phoenix.PubSub.subscribe(Radar.PubSub, @uploader_debug_topic)
      Phoenix.PubSub.subscribe(Radar.PubSub, Presence.uploader_topic())
    end

    config = RadarConfigs.get_config!()

    socket =
      socket
      |> assign(:config, config)
      |> assign(:form, config_to_form(config))
      |> assign(:infraction_count, Infractions.count_infractions())
      |> assign(:uploader_debug, %{connected: Presence.uploader_connected?(), logs: []})
      |> assign(:last_target, nil)
      |> push_config_event(config)

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
              data-radar-config={Jason.encode!(RadarConfigs.config_payload(@config))}
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
                    const viewRange = Math.max(cfg?.max_dist || 8000, 8000);
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
                      const radius = dot.triggered ? 8 : 7;

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

                      if (dot.triggered) {
                        ctx.beginPath();
                        ctx.arc(px, py, 14, 0, Math.PI * 2);
                        ctx.strokeStyle = `hsla(${hue}, 90%, 55%, ${opacity})`;
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
                  <span class="opacity-70">Cooldown</span>
                  <span class={debug_bool_class(@last_target.cooldown_elapsed)}>
                    {yes_no(@last_target.cooldown_elapsed)}
                  </span>
                  <span class="opacity-70">Capture paused</span>
                  <span class={debug_bool_class(!@last_target.capture_paused)}>
                    {yes_no(@last_target.capture_paused)}
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
                <span class="opacity-70">Uploader connected</span>
                <span class={uploader_status_class(@uploader_debug.connected)}>
                  {yes_no(@uploader_debug.connected)}
                </span>
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

  def handle_event("update_config", %{"config" => params}, socket) do
    db_params = form_params_to_db(params)

    case RadarConfigs.update_config(db_params) do
      {:ok, config} ->
        {:noreply,
         socket
         |> assign(:config, config)
         |> assign(:form, config_to_form(config))
         |> push_config_event(config)}

      {:error, _changeset} ->
        {:noreply, assign(socket, :form, to_form(params, as: :config))}
    end
  end

  def handle_event("toggle_capture", _params, socket) do
    case RadarConfigs.update_config(%{capture_paused: !socket.assigns.config.capture_paused}) do
      {:ok, config} ->
        {:noreply,
         socket
         |> assign(:config, config)
         |> assign(:form, config_to_form(config))
         |> push_config_event(config)}

      {:error, _changeset} ->
        {:noreply, socket}
    end
  end

  def handle_info({:config_updated, config}, socket) do
    {:noreply,
     socket
     |> assign(:config, config)
     |> assign(:form, config_to_form(config))
     |> push_config_event(config)}
  end

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

      {:noreply, update(socket, :uploader_debug, &%{&1 | connected: connected})}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:uploader_log, log}, socket) do
    {:noreply, update(socket, :uploader_debug, &append_uploader_log(&1, log))}
  end

  def handle_info({:target_data, data}, socket) do
    target = normalize_target_data(data)

    socket =
      if socket.assigns.uploader_debug.connected do
        socket
      else
        update(socket, :uploader_debug, &%{&1 | connected: true})
      end

    {:noreply,
     socket
     |> assign(:last_target, target)
     |> push_event("radar_point", Map.take(target, [:x, :y, :speed, :distance, :triggered]))}
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

  defp normalize_target_data(data) do
    %{
      raw_speed_cm_s: target_number(data, "raw_speed_cm_s", 0),
      speed: target_number(data, "speed", 0),
      x: target_number(data, "x", 0),
      y: target_number(data, "y", 0),
      distance: target_number(data, "distance", 0.0),
      angle: target_number(data, "angle", 0.0),
      in_range: target_bool(data, "in_range"),
      in_aperture: target_bool(data, "in_aperture"),
      over_speed: target_bool(data, "over_speed"),
      cooldown_elapsed: target_bool(data, "cooldown_elapsed"),
      capture_paused: target_bool(data, "capture_paused"),
      would_trigger: target_bool(data, "would_trigger"),
      triggered: target_bool(data, "triggered")
    }
  end

  defp target_number(data, key, default) do
    case Map.get(data, key, Map.get(data, String.to_existing_atom(key), default)) do
      value when is_number(value) -> value
      _value -> default
    end
  rescue
    ArgumentError -> Map.get(data, key, default)
  end

  defp target_bool(data, key) do
    case Map.get(data, key, Map.get(data, String.to_existing_atom(key), false)) do
      true -> true
      _value -> false
    end
  rescue
    ArgumentError -> Map.get(data, key, false) == true
  end

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

  defp push_config_event(socket, config) do
    push_event(socket, "radar_config", RadarConfigs.config_payload(config))
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
