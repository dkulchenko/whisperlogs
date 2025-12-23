defmodule WhisperLogs.Syslog.Supervisor do
  @moduledoc """
  Supervisor for syslog listeners.

  Uses a Registry for named process lookup and DynamicSupervisor for
  listener lifecycle management. Automatically starts all configured
  syslog sources on boot via handle_continue.
  """
  use Supervisor

  require Logger

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: WhisperLogs.Syslog.Registry},
      {DynamicSupervisor, name: WhisperLogs.Syslog.DynamicSupervisor, strategy: :one_for_one},
      # Starter process that loads existing syslog sources on boot
      {WhisperLogs.Syslog.Starter, []}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  @doc """
  Starts a syslog listener for the given source.
  """
  def start_listener(source) do
    DynamicSupervisor.start_child(
      WhisperLogs.Syslog.DynamicSupervisor,
      {WhisperLogs.Syslog.Listener, source: source}
    )
  end

  @doc """
  Stops a syslog listener for the given source ID.
  """
  def stop_listener(source_id) do
    case Registry.lookup(WhisperLogs.Syslog.Registry, source_id) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(WhisperLogs.Syslog.DynamicSupervisor, pid)

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Checks if a listener is running for the given source ID.
  """
  def listener_running?(source_id) do
    case Registry.lookup(WhisperLogs.Syslog.Registry, source_id) do
      [{_pid, _}] -> true
      [] -> false
    end
  end

  @doc """
  Restarts all syslog listeners from database.
  Called on application startup.
  """
  def start_all_listeners do
    sources = WhisperLogs.Accounts.list_syslog_sources()
    Logger.info("Starting #{length(sources)} syslog listener(s)")

    for source <- sources do
      case start_listener(source) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.error("Failed to start syslog listener for #{source.source}: #{inspect(reason)}")
      end
    end

    :ok
  end
end
