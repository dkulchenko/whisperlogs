defmodule WhisperLogs.SourceCache do
  @moduledoc """
  ETS-based cache for source authentication.

  Provides two functions:
  1. Cache source lookups by token (avoid DB reads on every log ingestion)
  2. Throttle `last_used_at` updates per source (reduce DB writes)

  The GenServer only owns the ETS table. All access is direct to ETS for maximum
  concurrency - no GenServer bottleneck.

  Configure TTLs in config.exs:

      config :whisperlogs, WhisperLogs.SourceCache,
        source_ttl: 15,   # seconds - how long to cache source lookups
        touch_ttl: 300    # seconds - how often to update last_used_at
  """

  use GenServer

  @table __MODULE__

  # Client API - all direct ETS access, no GenServer calls

  @doc """
  Returns cached source or `:miss` if not cached or expired.
  """
  def get_source(token) do
    case :ets.lookup(@table, {:source, token}) do
      [{_key, source, cached_at}] ->
        if expired?(cached_at, source_ttl()) do
          :miss
        else
          {:ok, source}
        end

      [] ->
        :miss
    end
  end

  @doc """
  Caches a source by its token.
  """
  def cache_source(token, source) do
    :ets.insert(@table, {{:source, token}, source, System.monotonic_time(:second)})
    :ok
  end

  @doc """
  Returns true if we should update `last_used_at` in the database.
  Returns false if we've touched this source within the TTL.
  """
  def should_touch?(source_id) do
    case :ets.lookup(@table, {:touched, source_id}) do
      [{_key, touched_at}] ->
        expired?(touched_at, touch_ttl())

      [] ->
        true
    end
  end

  @doc """
  Records that we've touched this source (updated `last_used_at`).
  """
  def mark_touched(source_id) do
    :ets.insert(@table, {{:touched, source_id}, System.monotonic_time(:second)})
    :ok
  end

  # Private helpers

  defp expired?(timestamp, ttl) do
    System.monotonic_time(:second) - timestamp > ttl
  end

  defp source_ttl do
    Application.get_env(:whisperlogs, __MODULE__)[:source_ttl] || 15
  end

  defp touch_ttl do
    Application.get_env(:whisperlogs, __MODULE__)[:touch_ttl] || 300
  end

  # GenServer - only for table ownership

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    :ets.new(@table, [
      :set,
      :named_table,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end
end
