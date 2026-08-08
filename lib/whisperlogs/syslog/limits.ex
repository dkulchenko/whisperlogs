defmodule WhisperLogs.Syslog.Limits do
  @moduledoc false
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, 0, name: __MODULE__)
  def reserve_queue, do: GenServer.call(__MODULE__, :reserve_queue)

  def release_queue(count \\ 1) when is_integer(count) and count >= 0,
    do: GenServer.cast(__MODULE__, {:release_queue, count})

  @impl true
  def init(count), do: {:ok, count}

  @impl true
  def handle_call(:reserve_queue, _from, count) do
    max = WhisperLogs.Config.syslog_limits().max_queued_global

    if count < max,
      do: {:reply, :ok, count + 1},
      else: {:reply, {:error, :global_queue_full}, count}
  end

  @impl true
  def handle_cast({:release_queue, released}, count), do: {:noreply, max(count - released, 0)}
end
