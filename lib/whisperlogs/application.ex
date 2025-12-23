defmodule WhisperLogs.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      WhisperLogsWeb.Telemetry,
      WhisperLogs.Repo,
      {DNSCluster, query: Application.get_env(:whisperlogs, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: WhisperLogs.PubSub},
      # Log retention cleanup
      WhisperLogs.Retention,
      # Syslog listener infrastructure
      WhisperLogs.Syslog.Supervisor,
      # Start to serve requests, typically the last entry
      WhisperLogsWeb.Endpoint
    ]

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
end
