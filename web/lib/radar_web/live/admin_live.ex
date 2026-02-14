defmodule RadarWeb.AdminLive do
  use RadarWeb, :live_view

  alias Radar.RadarConfigs
  alias Phoenix.LiveView.ColocatedHook

  @throttle_ms 100

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Radar.PubSub, "radar_config")
      Phoenix.PubSub.subscribe(Radar.PubSub, "radar_data")
    end

    config = RadarConfigs.get_config!()

    socket =
      socket
      |> assign(:config, config)
      |> assign(:form, config_to_form(config))
      |> assign(:last_ui_update, System.monotonic_time(:millisecond) - @throttle_ms)
      |> push_event("radar_config", %{
        min_dist: config.min_dist,
        max_dist: config.max_dist,
        authorized_speed: config.authorized_speed,
        trigger_cooldown: config.trigger_cooldown
      })

    {:ok, socket}
  end

  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto p-6 space-y-8">
      <h1 class="text-3xl font-bold">Radar Configuration</h1>

      <div class="card bg-base-200 shadow-lg">
        <div class="card-body">
          <h2 class="card-title">Trigger Parameters</h2>

          <.form for={@form} phx-change="update_config" class="space-y-4">
            <.input
              field={@form[:authorized_speed]}
              type="number"
              label="Authorized Speed (km/h)"
              min="1"
            />
            <.input
              field={@form[:min_dist]}
              type="number"
              label="Min Distance (meters)"
              min="0"
              step="0.1"
            />
            <.input
              field={@form[:max_dist]}
              type="number"
              label="Max Distance (meters)"
              min="0"
              step="0.1"
            />
            <.input
              field={@form[:trigger_cooldown]}
              type="number"
              label="Trigger Cooldown (seconds)"
              min="0"
              step="0.1"
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
                let cfg = null;
                const FADE_MS = 4000;
                const VIEW_RANGE = 15000;

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
                  const scale = h / VIEW_RANGE;

                  while (dots.length > 0 && now - dots[0].time > FADE_MS) dots.shift();

                  ctx.fillStyle = "#191e24";
                  ctx.fillRect(0, 0, w, h);

                  if (cfg) {
                    const cx = w / 2;
                    const cy = h;
                    ctx.setLineDash([4, 4]);
                    ctx.lineWidth = 1;
                    ctx.strokeStyle = "rgba(255, 255, 255, 0.15)";

                    ctx.beginPath();
                    ctx.arc(cx, cy, cfg.min_dist * scale, Math.PI, 0);
                    ctx.stroke();

                    ctx.beginPath();
                    ctx.arc(cx, cy, cfg.max_dist * scale, Math.PI, 0);
                    ctx.stroke();

                    ctx.setLineDash([]);
                  }

                  for (const dot of dots) {
                    const age = now - dot.time;
                    const opacity = 1 - age / FADE_MS;
                    const px = w / 2 + dot.x * scale;
                    const py = h - dot.y * scale;

                    const ratio = cfg ? Math.min(dot.speed / (cfg.authorized_speed * 2), 1) : 0.5;
                    const hue = 120 * (1 - ratio);

                    ctx.beginPath();
                    ctx.arc(px, py, 5, 0, Math.PI * 2);
                    ctx.fillStyle = `hsla(${hue}, 90%, 55%, ${opacity})`;
                    ctx.fill();

                    if (dot.triggered) {
                      ctx.beginPath();
                      ctx.arc(px, py, 12, 0, Math.PI * 2);
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
        </div>
      </div>
    </div>
    """
  end

  def handle_event("update_config", %{"config" => params}, socket) do
    db_params = form_params_to_db(params)

    case RadarConfigs.update_config(db_params) do
      {:ok, _config} ->
        {:noreply, assign(socket, :form, to_form(params, as: :config))}

      {:error, _changeset} ->
        {:noreply, assign(socket, :form, to_form(params, as: :config))}
    end
  end

  def handle_info({:config_updated, config}, socket) do
    {:noreply,
     socket
     |> assign(:config, config)
     |> assign(:form, config_to_form(config))
     |> push_event("radar_config", %{
       min_dist: config.min_dist,
       max_dist: config.max_dist,
       authorized_speed: config.authorized_speed,
       trigger_cooldown: config.trigger_cooldown
     })}
  end

  def handle_info({:target_data, data}, socket) do
    now = System.monotonic_time(:millisecond)

    if now - socket.assigns.last_ui_update >= @throttle_ms do
      {:noreply,
       socket
       |> push_event("radar_point", %{
         x: data["x"],
         y: data["y"],
         speed: data["speed"],
         distance: data["distance"],
         triggered: data["triggered"]
       })
       |> assign(:last_ui_update, now)}
    else
      {:noreply, socket}
    end
  end

  defp config_to_form(config) do
    to_form(
      %{
        "authorized_speed" => config.authorized_speed,
        "min_dist" => config.min_dist / 1000,
        "max_dist" => config.max_dist / 1000,
        "trigger_cooldown" => config.trigger_cooldown / 1000
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
      "trigger_cooldown" => round(cooldown_s * 1000)
    }
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
