import Config

config :radar, api_keys: ["radar-dev-key"]

# Configure mock S3 client for tests
config :radar, :s3_client, Radar.MockS3Client

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :radar, Radar.Repo,
  database: Path.expand("../radar_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :radar, RadarWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "u1W0jO/I/HpdhBUb88Gc/gJl2tkvBkL10OWyOCmMHTl1hmqpq/H5gPixrfcJFrEN",
  server: false

# In test we don't send emails
config :radar, Radar.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Google OAuth stubs for tests
config :ueberauth, Ueberauth.Strategy.Google.OAuth,
  client_id: "test-client-id",
  client_secret: "test-client-secret"

config :radar, :admin_emails, ["admin@test.com"]
