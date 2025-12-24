defmodule WhisperLogs.Shipper do
  @moduledoc """
  Buffers log events and ships them to WhisperLogs in batches.

  Logs are buffered and flushed either when the batch size is reached or
  after a configured interval, whichever comes first. HTTP requests are
  made asynchronously to avoid blocking the logger.

  ## Configuration

      config :whisperlogs_shipper,
        enabled: true,
        endpoint: "https://logs.example.com/api/v1/logs",
        auth_token: "wl_your_api_key",
        batch_size: 100,
        flush_interval_ms: 1_000

  ## Usage

  The shipper starts automatically when `:enabled` is true. All logs
  are automatically captured via the Erlang :logger handler.
  """
  use GenServer

  alias WhisperLogs.Shipper.Tasks

  defstruct [
    :endpoint,
    :auth_token,
    :batch_size,
    :flush_interval_ms,
    :receive_timeout,
    :source_name,
    buffer: [],
    buffer_size: 0
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Adds a log event to the buffer. Non-blocking (cast).
  """
  def log(event) do
    GenServer.cast(__MODULE__, {:log, event})
  end

  @doc """
  Forces an immediate flush of the buffer. Useful for testing or graceful shutdown.
  """
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  @impl GenServer
  def init(_opts) do
    endpoint = get_config(:endpoint)
    auth_token = get_config(:auth_token)

    if !(is_binary(endpoint) and endpoint != "") do
      raise ArgumentError,
            "WhisperLogs.Shipper :endpoint must be a non-empty string, got: #{inspect(endpoint)}"
    end

    if !(is_binary(auth_token) and auth_token != "") do
      raise ArgumentError,
            "WhisperLogs.Shipper :auth_token must be a non-empty string, got: #{inspect(auth_token)}"
    end

    state = %__MODULE__{
      endpoint: endpoint,
      auth_token: auth_token,
      batch_size: get_config(:batch_size, 100),
      flush_interval_ms: get_config(:flush_interval_ms, 1_000),
      receive_timeout: get_config(:receive_timeout, 10_000),
      source_name: get_config(:source_name),
      buffer: [],
      buffer_size: 0
    }

    :logger.add_handler(:whisperlogs_shipper, WhisperLogs.Shipper.Handler, %{})
    schedule_flush(state.flush_interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :logger.remove_handler(:whisperlogs_shipper)
    :ok
  end

  @impl GenServer
  def handle_cast({:log, event}, state) do
    buffer = [event | state.buffer]
    buffer_size = state.buffer_size + 1

    if buffer_size >= state.batch_size do
      ship_logs(buffer, state)
      {:noreply, %{state | buffer: [], buffer_size: 0}}
    else
      {:noreply, %{state | buffer: buffer, buffer_size: buffer_size}}
    end
  end

  @impl GenServer
  def handle_call(:flush, _from, %{buffer: []} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:flush, _from, state) do
    ship_logs(state.buffer, state)
    {:reply, :ok, %{state | buffer: [], buffer_size: 0}}
  end

  @impl GenServer
  def handle_info(:flush, %{buffer: []} = state) do
    schedule_flush(state.flush_interval_ms)
    {:noreply, state}
  end

  def handle_info(:flush, state) do
    ship_logs(state.buffer, state)
    schedule_flush(state.flush_interval_ms)
    {:noreply, %{state | buffer: [], buffer_size: 0}}
  end

  defp schedule_flush(interval_ms) do
    Process.send_after(self(), :flush, interval_ms)
  end

  defp ship_logs(buffer, state) do
    logs = Enum.reverse(buffer)
    log_count = length(logs)
    endpoint = state.endpoint
    auth_token = state.auth_token
    receive_timeout = state.receive_timeout
    test_opts = get_config(:req_test_options, [])

    Tasks.start_child(fn ->
      opts =
        [
          json: %{logs: logs},
          headers: [{"authorization", "Bearer #{auth_token}"}],
          receive_timeout: receive_timeout
        ] ++ test_opts

      case Req.post(endpoint, opts) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status}} ->
          # Use IO.warn to bypass Logger and avoid infinite loop
          IO.warn("[WhisperLogs.Shipper] HTTP #{status} shipping #{log_count} logs to #{endpoint}")

        {:error, exception} ->
          IO.warn(
            "[WhisperLogs.Shipper] Failed to ship #{log_count} logs: #{Exception.message(exception)}"
          )
      end
    end)
  end

  defp get_config(key, default \\ nil) do
    Application.get_env(:whisperlogs_shipper, key, default)
  end
end
