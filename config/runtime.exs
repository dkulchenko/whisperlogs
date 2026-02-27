import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# Determine database adapter at runtime based on DATABASE_URL
# This must be set before any Repo config and before the app starts
adapter = if System.get_env("DATABASE_URL"), do: :postgres, else: :sqlite
config :whisperlogs, :db_adapter, adapter

# Always start the server in production mode (for releases/Burrito builds)
if config_env() == :prod do
  config :whisperlogs, WhisperLogsWeb.Endpoint, server: true
end

if config_env() == :prod do
  # Database configuration: PostgreSQL if DATABASE_URL is set, otherwise SQLite
  if database_url = System.get_env("DATABASE_URL") do
    maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

    config :whisperlogs, WhisperLogs.Repo.Postgres,
      # ssl: true,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
      socket_options: maybe_ipv6
  else
    # SQLite mode - use XDG_DATA_HOME (defaults to ~/.local/share)
    db_path =
      System.get_env("DATABASE_PATH") ||
        Path.join(
          System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"),
          "whisperlogs/db.sqlite"
        )

    # Platform detection for SQLean regexp extension
    sqlean_platform =
      case :os.type() do
        {:unix, :darwin} ->
          arch = :erlang.system_info(:system_architecture) |> List.to_string()

          if String.contains?(arch, "aarch64") or String.contains?(arch, "arm"),
            do: "macos-arm64",
            else: "macos-x64"

        {:unix, :linux} ->
          arch = :erlang.system_info(:system_architecture) |> List.to_string()

          if String.contains?(arch, "aarch64") or String.contains?(arch, "arm"),
            do: "linux-arm64",
            else: "linux-x64"

        {:win32, _} ->
          "win-x64"
      end

    regexp_ext =
      Path.join(
        :code.priv_dir(:whisperlogs) |> to_string(),
        "sqlite_extensions/#{sqlean_platform}/regexp"
      )

    config :whisperlogs, WhisperLogs.Repo.SQLite,
      database: db_path,
      load_extensions: [regexp_ext],
      pool_size: 10,
      journal_mode: :wal,
      busy_timeout: 5000,
      synchronous: :normal,
      cache_size: -64000,
      temp_store: :memory
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # In SQLite mode (local/single-user), we auto-generate one for zero-config experience.
  # In PostgreSQL mode (production), require it to be set explicitly.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      if adapter == :sqlite do
        # Auto-generate for SQLite mode - sessions won't persist across restarts
        # but that's acceptable for local single-user deployments
        :crypto.strong_rand_bytes(64) |> Base.encode64()
      else
        raise """
        environment variable SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """
      end

  host = System.get_env("PHX_HOST") || "localhost"

  config :whisperlogs, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  port = String.to_integer(System.get_env("PORT") || "4050")

  # URL config: use HTTPS/443 when behind a reverse proxy, otherwise HTTP with actual port
  {url_scheme, url_port} =
    if System.get_env("PHX_HOST") do
      # Custom host set - assume behind reverse proxy with HTTPS
      {"https", 443}
    else
      # Standalone mode - use HTTP with actual port
      {"http", port}
    end

  # In standalone mode, disable origin checking since users may access via various hostnames
  check_origin = if System.get_env("PHX_HOST"), do: true, else: false

  config :whisperlogs, WhisperLogsWeb.Endpoint,
    url: [host: host, port: url_port, scheme: url_scheme],
    check_origin: check_origin,
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :whisperlogs, WhisperLogsWeb.Endpoint,
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
  #     config :whisperlogs, WhisperLogsWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :whisperlogs, WhisperLogs.Mailer,
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
