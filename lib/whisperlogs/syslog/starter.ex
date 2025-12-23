defmodule WhisperLogs.Syslog.Starter do
  @moduledoc """
  GenServer that starts all configured syslog listeners on boot.
  Uses handle_continue to defer the startup work after init completes.
  """
  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}, {:continue, :start_listeners}}
  end

  @impl true
  def handle_continue(:start_listeners, state) do
    sources = WhisperLogs.Accounts.list_syslog_sources()
    Logger.info("Starting #{length(sources)} syslog listener(s)")

    for source <- sources do
      case WhisperLogs.Syslog.Supervisor.start_listener(source) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          Logger.error("Failed to start syslog listener for #{source.source}: #{inspect(reason)}")
      end
    end

    {:noreply, state}
  end
end
