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
      WhisperLogs.Syslog.Limits,
      {Task.Supervisor,
       name: WhisperLogs.Syslog.IngestSupervisor,
       max_children: WhisperLogs.Config.syslog_limits().ingest_workers},
      {DynamicSupervisor,
       name: WhisperLogs.Syslog.ConnectionSupervisor,
       strategy: :one_for_one,
       max_children: WhisperLogs.Config.syslog_limits().max_connections},
      {DynamicSupervisor, name: WhisperLogs.Syslog.DynamicSupervisor, strategy: :one_for_one}
    ]

    children =
      if Application.get_env(:whisperlogs, :start_background_workers, true) do
        children ++ [{WhisperLogs.Syslog.Starter, []}]
      else
        children
      end

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

  def replace_policy(source) do
    case Registry.lookup(WhisperLogs.Syslog.Registry, source.id) do
      [{pid, _}] -> GenServer.call(pid, {:replace_policy, source})
      [] -> {:error, :not_found}
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
    case WhisperLogs.Accounts.validated_syslog_sources_for_startup() do
      {:ok, sources} ->
        Logger.info("Starting #{length(sources)} syslog listener(s)")

        for source <- sources do
          case start_listener(source) do
            {:ok, _pid} ->
              :ok

            {:error, reason} ->
              Logger.error(
                "Failed to start syslog listener for #{source.source}: #{inspect(reason)}"
              )
          end
        end

      {:error, reason} ->
        Logger.error(
          "No syslog listeners started because persisted configuration is invalid: #{inspect(reason)}"
        )
    end

    :ok
  end
end
