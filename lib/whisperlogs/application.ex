defmodule WhisperLogs.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    WhisperLogs.Config.validate!()

    # For SQLite mode, auto-create database and run migrations on startup
    # This makes it work out of the box without manual setup
    maybe_auto_migrate()

    # Start the correct repo based on runtime config (set in runtime.exs)
    repo =
      if WhisperLogs.DbAdapter.sqlite?() do
        WhisperLogs.Repo.SQLite
      else
        WhisperLogs.Repo.Postgres
      end

    infrastructure = [
      WhisperLogsWeb.Telemetry,
      repo,
      WhisperLogs.Accounts.Bootstrap,
      {Phoenix.PubSub, name: WhisperLogs.PubSub},
      {Task.Supervisor, name: WhisperLogs.Alerts.PreviewSupervisor, max_children: 2},
      # Syslog listener infrastructure
      WhisperLogs.Syslog.Supervisor,
      # Start to serve requests, typically the last entry
      WhisperLogsWeb.Endpoint
    ]

    background_workers = [
      # Export scheduler runs before retention so archival gets the first chance at data.
      WhisperLogs.Exports.Scheduler,
      WhisperLogs.Retention,
      WhisperLogs.Alerts.Evaluator
    ]

    children =
      if Application.get_env(:whisperlogs, :start_background_workers, true) do
        Enum.drop(infrastructure, -1) ++ background_workers ++ [List.last(infrastructure)]
      else
        infrastructure
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: WhisperLogs.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    WhisperLogsWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Auto-migrate for SQLite mode only
  # Disabled in test env via config, PostgreSQL users run migrations manually
  defp maybe_auto_migrate do
    auto_migrate? = Application.get_env(:whisperlogs, :auto_migrate, true)

    if auto_migrate? && WhisperLogs.DbAdapter.sqlite?() do
      WhisperLogs.Release.create_and_migrate()
    end
  end
end
