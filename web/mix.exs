defmodule Radar.MixProject do
  use Mix.Project

  def project do
    [
      app: :radar,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: extra_compilers(Mix.env()) ++ [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      dialyzer: [plt_add_apps: [:mix]],
      unused: [
        ignore: [
          # All generated __dunder__ functions (Ecto, Phoenix, LiveView, etc.)
          {:_, ~r/^__.*__\??$/},
          # OTP callbacks (invoked by supervisors, not direct calls)
          {:_, :child_spec, 1},
          {:_, :start_link, 1},
          # Ecto repo (all generated)
          Radar.Repo,
          # Phoenix framework modules (router, endpoint, components, layouts, telemetry, errors)
          RadarWeb,
          RadarWeb.Router,
          RadarWeb.Endpoint,
          RadarWeb.Telemetry,
          RadarWeb.CoreComponents,
          RadarWeb.Layouts,
          RadarWeb.ErrorJSON,
          # Controller actions (dispatched by router)
          {~r/Controller$/, :_, 2},
          # HEEx template render callbacks
          {~r/HTML$/, :_, :_},
          # Generated modules
          Radar.Release,
          Radar.Mailer,
          # S3 behaviour callbacks
          Radar.S3,
          # Context functions called from controllers (invisible to tracer)
          {Radar.Photos, :create_photo, 1},
          {Radar.Photos, :get_photo_url, 2},
          # LiveView on_mount hooks (invoked by framework)
          RadarWeb.AdminAuth
        ]
      ]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Radar.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp extra_compilers(:dev), do: [:unused]
  defp extra_compilers(_), do: []

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.0"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:phoenix_live_view, "~> 1.1.0-rc.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:ex_aws, "~> 2.1"},
      {:ex_aws_s3, "~> 2.0"},
      {:hackney, "~> 1.9"},
      {:qr_code, "~> 3.1"},
      {:sweet_xml, "~> 0.6"},
      {:mox, "~> 1.0", only: :test},
      {:tidewave, "~> 0.5", only: :dev},
      {:igniter, "~> 0.7"},
      {:ex_check, "~> 0.16", only: :dev, runtime: false},
      {:mix_unused, "~> 0.4", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:ueberauth, "~> 0.10"},
      {:ueberauth_google, "~> 0.12"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind radar", "esbuild radar"],
      "assets.deploy": [
        "tailwind radar --minify",
        "esbuild radar --minify",
        "phx.digest"
      ]
    ]
  end
end
