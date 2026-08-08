defmodule WhisperLogs.Syslog.Starter do
  @moduledoc """
  GenServer that starts all configured syslog listeners on boot.
  Uses handle_continue to defer the startup work after init completes.
  """
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}, {:continue, :start_listeners}}
  end

  @impl true
  def handle_continue(:start_listeners, state) do
    WhisperLogs.Syslog.Supervisor.start_all_listeners()
    {:noreply, state}
  end
end
