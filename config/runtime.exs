import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# Determine database adapter at runtime.
# Tests default to PostgreSQL so the authenticated/multi-user path is covered
# by normal `mix test`; set WHISPERLOGS_TEST_ADAPTER=sqlite for SQLite-only runs.
adapter =
  cond do
    config_env() == :test and System.get_env("WHISPERLOGS_TEST_ADAPTER") == "sqlite" ->
      :sqlite

    config_env() == :test ->
      :postgres

    System.get_env("DATABASE_URL") ->
      :postgres

    true ->
      :sqlite
  end

config :whisperlogs, :db_adapter, adapter

parse_positive_integer = fn name, default ->
  value = System.get_env(name) || Integer.to_string(default)

  case Integer.parse(value) do
    {integer, ""} when integer > 0 -> integer
    _ -> raise "#{name} must be a positive integer"
  end
end

parse_ip = fn name, default ->
  value = System.get_env(name) || default

  case :inet.parse_address(String.to_charlist(value)) do
    {:ok, address} -> address
    {:error, :einval} -> raise "#{name} must be an IP literal"
  end
end

parse_hosts = fn value ->
  case value do
    nil -> []
    "" -> []
    hosts -> String.split(hosts, ",", trim: false) |> Enum.map(&String.trim/1)
  end
end

# Always start the server in production mode (for releases/Burrito builds)
if config_env() == :prod do
  config :whisperlogs, WhisperLogsWeb.Endpoint, server: true
end

if config_env() == :prod do
  # Database configuration: PostgreSQL if DATABASE_URL is set, otherwise SQLite
  database_path =
    if adapter == :sqlite do
      System.get_env("DATABASE_PATH") ||
        Path.join(
          System.get_env("XDG_DATA_HOME") || Path.expand("~/.local/share"),
          "whisperlogs/db.sqlite"
        )
    end

  if database_url = System.get_env("DATABASE_URL") do
    maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

    config :whisperlogs, WhisperLogs.Repo.Postgres,
      # ssl: true,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
      socket_options: maybe_ipv6
  else
    regexp_ext = WhisperLogs.SQLean.verified_extension_path!()

    config :whisperlogs, WhisperLogs.Repo.SQLite,
      database: database_path,
      load_extensions: [regexp_ext],
      pool_size: 10,
      journal_mode: :wal,
      busy_timeout: 5000,
      synchronous: :normal,
      cache_size: -64000,
      temp_store: :memory
  end

  generated_secret_file =
    if database_path, do: Path.join(Path.dirname(database_path), "secret_key_base")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      if adapter == :sqlite do
        File.mkdir_p!(Path.dirname(generated_secret_file))

        case File.lstat(generated_secret_file) do
          {:ok, %{type: :regular, mode: mode}} ->
            if Bitwise.band(mode, 0o077) != 0 do
              raise "#{generated_secret_file} must not be group/world accessible"
            end

          {:ok, _stat} ->
            raise "#{generated_secret_file} must be a regular, non-symlink file"

          {:error, :enoent} ->
            secret = :crypto.strong_rand_bytes(64) |> Base.encode64()

            generated_secret_file
            |> File.open!([:write, :exclusive])
            |> then(fn io ->
              try do
                # The exclusively-created file contains no secret until its mode is private.
                File.chmod!(generated_secret_file, 0o600)
                IO.binwrite(io, secret)
              after
                File.close(io)
              end
            end)

          {:error, reason} ->
            raise "cannot inspect #{generated_secret_file}: #{inspect(reason)}"
        end

        value = File.read!(generated_secret_file)

        if byte_size(value) < 64 or byte_size(value) > 1_024 do
          raise "#{generated_secret_file} must contain 64..1024 bytes"
        end

        value
      else
        raise """
        environment variable SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """
      end

  host = System.get_env("PHX_HOST") || "localhost"

  config :whisperlogs, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  port = parse_positive_integer.("PORT", 4050)
  bind_ip = parse_ip.("WHISPERLOGS_BIND_IP", "127.0.0.1")
  loopback_host? = host in ["localhost", "127.0.0.1", "::1", "[::1]"]

  config :whisperlogs, :secure_cookies, not loopback_host?

  config :whisperlogs, :receiver_limits, %{
    max_request_bytes: parse_positive_integer.("WHISPERLOGS_MAX_REQUEST_BYTES", 8_000_000),
    max_batch_size: parse_positive_integer.("WHISPERLOGS_MAX_BATCH_SIZE", 250),
    max_message_bytes: parse_positive_integer.("WHISPERLOGS_MAX_MESSAGE_BYTES", 65_536),
    max_metadata_bytes: parse_positive_integer.("WHISPERLOGS_MAX_METADATA_BYTES", 131_072),
    max_metadata_depth: parse_positive_integer.("WHISPERLOGS_MAX_METADATA_DEPTH", 8),
    max_event_bytes: parse_positive_integer.("WHISPERLOGS_MAX_EVENT_BYTES", 262_144)
  }

  config :whisperlogs, :export_limits, %{
    max_range_days: parse_positive_integer.("WHISPERLOGS_EXPORT_MAX_RANGE_DAYS", 31),
    max_pending_per_user: parse_positive_integer.("WHISPERLOGS_EXPORT_MAX_PENDING_PER_USER", 2),
    max_pending_global: parse_positive_integer.("WHISPERLOGS_EXPORT_MAX_PENDING_GLOBAL", 10),
    max_rows: parse_positive_integer.("WHISPERLOGS_EXPORT_MAX_ROWS", 2_000_000),
    max_compressed_bytes:
      parse_positive_integer.("WHISPERLOGS_EXPORT_MAX_COMPRESSED_BYTES", 536_870_912),
    timeout_seconds: parse_positive_integer.("WHISPERLOGS_EXPORT_TIMEOUT_SECONDS", 1_800)
  }

  export_root =
    System.get_env("WHISPERLOGS_EXPORT_ROOT") ||
      if database_path do
        Path.join(Path.dirname(database_path), "exports")
      else
        raise "WHISPERLOGS_EXPORT_ROOT is required with PostgreSQL"
      end

  config :whisperlogs, :export_root, export_root

  config :whisperlogs, :alert_limits, %{
    max_concurrency: parse_positive_integer.("WHISPERLOGS_ALERT_MAX_CONCURRENCY", 2),
    query_timeout_ms: parse_positive_integer.("WHISPERLOGS_ALERT_QUERY_TIMEOUT_MS", 5_000),
    cycle_timeout_ms: parse_positive_integer.("WHISPERLOGS_ALERT_CYCLE_TIMEOUT_MS", 20_000)
  }

  config :whisperlogs, :mcp_limits, %{
    query_timeout_ms: parse_positive_integer.("WHISPERLOGS_MCP_QUERY_TIMEOUT_MS", 5_000),
    max_response_bytes: parse_positive_integer.("WHISPERLOGS_MCP_MAX_RESPONSE_BYTES", 1_048_576),
    max_query_bytes: parse_positive_integer.("WHISPERLOGS_MCP_MAX_QUERY_BYTES", 4_096)
  }

  config :whisperlogs, :syslog_limits, %{
    max_connections: parse_positive_integer.("WHISPERLOGS_SYSLOG_MAX_CONNECTIONS", 128),
    max_connections_per_source:
      parse_positive_integer.("WHISPERLOGS_SYSLOG_MAX_CONNECTIONS_PER_SOURCE", 32),
    max_frame_bytes: parse_positive_integer.("WHISPERLOGS_SYSLOG_MAX_FRAME_BYTES", 65_536),
    max_queued_per_source:
      parse_positive_integer.("WHISPERLOGS_SYSLOG_MAX_QUEUED_PER_SOURCE", 128),
    max_queued_global: parse_positive_integer.("WHISPERLOGS_SYSLOG_MAX_QUEUED_GLOBAL", 512),
    ingest_workers: parse_positive_integer.("WHISPERLOGS_SYSLOG_INGEST_WORKERS", 2),
    idle_timeout_ms: parse_positive_integer.("WHISPERLOGS_SYSLOG_IDLE_TIMEOUT_MS", 300_000),
    tls_handshake_timeout_ms:
      parse_positive_integer.("WHISPERLOGS_SYSLOG_TLS_HANDSHAKE_TIMEOUT_MS", 5_000)
  }

  config :whisperlogs,
         :s3_allowed_hosts,
         parse_hosts.(System.get_env("WHISPERLOGS_S3_ALLOWED_HOSTS"))

  # Loopback hosts are the native/Compose HTTP quick start. Other hosts are expected
  # to sit behind an HTTPS reverse proxy.
  {url_scheme, url_port} =
    if loopback_host?, do: {"http", port}, else: {"https", 443}

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
      ip: bind_ip,
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
