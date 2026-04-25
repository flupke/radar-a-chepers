import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/radar start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :radar, RadarWeb.Endpoint, server: true
end

if config_env() == :dev do
  fly_app = System.get_env("FLY_APP") || "rshep"
  fly_url = System.get_env("FLY_APP_URL") || "https://#{fly_app}.fly.dev/"

  fetch_fly_secret = fn name ->
    case System.cmd("fly", ["ssh", "console", "--app", fly_app, "-C", "printenv #{name}", "-q"],
           stderr_to_stdout: true
         ) do
      {value, 0} ->
        case String.trim(value) do
          "" -> nil
          value -> value
        end

      {reason, _status} ->
        IO.puts(
          :stderr,
          "Could not fetch #{name} from Fly app #{fly_app}: #{String.trim(reason)}"
        )

        nil
    end
  end

  wake_fly_app = fn ->
    IO.puts(:stderr, "Waking Fly app #{fly_app} at #{fly_url}...")

    Application.ensure_all_started(:ssl)
    Application.ensure_all_started(:inets)

    case :httpc.request(
           :get,
           {String.to_charlist(fly_url), []},
           [timeout: 30_000],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, _headers, _body}} when status in 200..599 ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Could not wake Fly app #{fly_app}: #{inspect(reason)}")
        :error
    end
  end

  secret_names = ~w(GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET)
  missing_secret_names = Enum.filter(secret_names, &(System.get_env(&1) |> is_nil()))

  fetched_any? =
    Enum.reduce(missing_secret_names, false, fn name, fetched_any? ->
      case fetch_fly_secret.(name) do
        nil ->
          fetched_any?

        value ->
          System.put_env(name, value)
          true
      end
    end)

  if missing_secret_names != [] and not fetched_any? do
    wake_fly_app.()

    for name <- missing_secret_names,
        is_nil(System.get_env(name)),
        value = fetch_fly_secret.(name),
        not is_nil(value) do
      System.put_env(name, value)
    end
  end
end

# Google OAuth for admin (all environments, runtime)
if client_id = System.get_env("GOOGLE_CLIENT_ID") do
  config :ueberauth, Ueberauth.Strategy.Google.OAuth,
    client_id: client_id,
    client_secret: System.fetch_env!("GOOGLE_CLIENT_SECRET")
end

if admin_emails = System.get_env("ADMIN_EMAILS") do
  config :radar, :admin_emails, admin_emails |> String.split(",") |> Enum.map(&String.trim/1)
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/radar/radar.db
      """

  config :radar, Radar.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :radar, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :radar, RadarWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  config :radar, api_keys: [System.get_env("RADAR_API_KEY") || raise("Missing RADAR_API_KEY")]

  config :ex_aws,
    access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
    secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY"),
    region: System.fetch_env!("AWS_REGION")

  s3_endpoint_url = System.fetch_env!("AWS_ENDPOINT_URL_S3")
  uri = URI.parse(s3_endpoint_url)
  config :ex_aws, :s3, host: uri.host, scheme: "#{uri.scheme}://", port: uri.port

  config :radar, s3_bucket: System.fetch_env!("BUCKET_NAME")

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :radar, RadarWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :radar, RadarWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :radar, Radar.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
