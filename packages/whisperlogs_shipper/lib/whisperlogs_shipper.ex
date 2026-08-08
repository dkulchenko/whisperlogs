defmodule WhisperLogs.Shipper do
  @moduledoc "A bounded, retrying WhisperLogs logger shipper."
  use GenServer

  @admission_key {__MODULE__, :admission}
  @prefix ~s({"logs":[)
  @suffix "]}"
  @max_response_bytes 65_536

  defstruct [
    :endpoint,
    :auth_token,
    :batch_size,
    :flush_interval_ms,
    :receive_timeout,
    :max_request_bytes,
    :admission,
    :flush_timer,
    :retry_timer,
    in_flight: nil,
    retry_attempt: 0,
    pending: :queue.new()
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def log(event) do
    with {:ok, encoded} <- normalize_and_encode(event), :ok <- reserve(byte_size(encoded)) do
      GenServer.cast(__MODULE__, {:log, encoded})
      :ok
    else
      {:error, reason} ->
        warn_drop(reason)
        :dropped
    end
  end

  def flush, do: GenServer.call(__MODULE__, :flush, :infinity)

  @impl true
  def init(_opts) do
    limits = limits!()
    admission = :atomics.new(2, signed: false)
    :persistent_term.put(@admission_key, {admission, limits})
    endpoint = required_string!(:endpoint)
    token = required_string!(:auth_token)
    :ok = add_handler()

    state = %__MODULE__{
      endpoint: endpoint,
      auth_token: token,
      batch_size: limits.batch_size,
      flush_interval_ms: limits.flush_interval_ms,
      receive_timeout: limits.receive_timeout,
      max_request_bytes: limits.max_request_bytes,
      admission: admission
    }

    {:ok, schedule_flush(state)}
  end

  @impl true
  def terminate(_reason, state) do
    :logger.remove_handler(:whisperlogs_shipper)

    case :persistent_term.get(@admission_key, nil) do
      {ref, _} when ref == state.admission -> :persistent_term.erase(@admission_key)
      _ -> :ok
    end

    :ok
  end

  @impl true
  def handle_cast({:log, encoded}, state) do
    state = %{state | pending: :queue.in(encoded, state.pending)}
    state = if ready?(state), do: send_next(state), else: state
    {:noreply, schedule_flush(state)}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    state = if state.in_flight == nil, do: send_next(state), else: state
    {:reply, :ok, schedule_flush(state)}
  end

  @impl true
  def handle_info(:flush, state) do
    state = %{state | flush_timer: nil}
    state = if state.in_flight == nil, do: send_next(state), else: state
    {:noreply, schedule_flush(state)}
  end

  def handle_info(:retry, %{in_flight: nil} = state), do: {:noreply, %{state | retry_timer: nil}}

  def handle_info(:retry, state) do
    state = %{state | retry_timer: nil}
    {:noreply, state |> perform_request() |> schedule_flush()}
  end

  defp send_next(%{in_flight: nil} = state) do
    case take_batch(state.pending, state.batch_size, state.max_request_bytes) do
      {[], _queue} ->
        state

      {events, queue} ->
        body = [@prefix, Enum.intersperse(events, ","), @suffix] |> IO.iodata_to_binary()

        %{state | pending: queue, in_flight: {events, body}, retry_attempt: 0}
        |> perform_request()
    end
  end

  defp send_next(state), do: state

  defp perform_request(%{in_flight: {events, body}} = state) do
    opts =
      [
        body: body,
        headers: [
          {"authorization", "Bearer #{state.auth_token}"},
          {"content-type", "application/json"}
        ],
        receive_timeout: state.receive_timeout,
        request_timeout: state.receive_timeout,
        retry: false,
        raw: true,
        into: &collect_bounded_response/2
      ] ++ get(:req_test_options, [])

    case Req.post(state.endpoint, opts) do
      {:ok, %{private: %{whisperlogs_body_too_large: true}}} ->
        schedule_retry(state)

      {:ok, %{status: status}} when status in 200..299 ->
        complete_batch(state, events)

      {:ok, %{status: status}} when status in [408, 425, 429] or status in 500..599 ->
        schedule_retry(state)

      {:ok, %{status: status}} ->
        warn_drop({:terminal_http_status, status})
        complete_batch(state, events)

      {:error, _reason} ->
        schedule_retry(state)
    end
  end

  defp complete_batch(state, events) do
    release(events)
    state = %{state | in_flight: nil, retry_attempt: 0, retry_timer: nil}
    if :queue.is_empty(state.pending), do: state, else: send_next(state)
  end

  defp schedule_retry(%{retry_timer: ref} = state) when not is_nil(ref), do: state

  defp schedule_retry(state) do
    attempt = state.retry_attempt + 1
    cap = min(trunc(:math.pow(2, min(attempt, 16))) * 1_000, 60_000)
    delay = :rand.uniform(cap) - 1
    %{state | retry_attempt: attempt, retry_timer: Process.send_after(self(), :retry, delay)}
  end

  defp take_batch(queue, max_count, max_bytes),
    do: take_batch(queue, max_count, max_bytes, [], byte_size(@prefix) + byte_size(@suffix))

  defp take_batch(queue, 0, _max, acc, _bytes), do: {Enum.reverse(acc), queue}

  defp take_batch(queue, remaining, max, acc, bytes) do
    case :queue.out(queue) do
      {:empty, queue} ->
        {Enum.reverse(acc), queue}

      {{:value, event}, rest} ->
        addition = byte_size(event) + if(acc == [], do: 0, else: 1)

        if bytes + addition <= max,
          do: take_batch(rest, remaining - 1, max, [event | acc], bytes + addition),
          else: {Enum.reverse(acc), queue}
    end
  end

  defp ready?(state), do: state.in_flight == nil and :queue.len(state.pending) >= state.batch_size

  defp schedule_flush(%{flush_timer: nil} = state),
    do: %{state | flush_timer: Process.send_after(self(), :flush, state.flush_interval_ms)}

  defp schedule_flush(state), do: state

  defp normalize_and_encode(event) when is_map(event) do
    limits =
      case :persistent_term.get(@admission_key, nil) do
        {_ref, limits} -> limits
        nil -> limits!()
      end

    message = Map.get(event, :message, Map.get(event, "message", ""))
    metadata = Map.get(event, :metadata, Map.get(event, "metadata", %{}))
    level = Map.get(event, :level, Map.get(event, "level", "info"))
    timestamp = Map.get(event, :timestamp, Map.get(event, "timestamp"))

    cond do
      not is_binary(message) or not String.valid?(message) or
          byte_size(message) > limits.max_message_bytes ->
        {:error, :message_limit}

      not is_map(metadata) or depth(metadata) > limits.max_metadata_depth ->
        {:error, :metadata_depth}

      encoded_size(metadata) > limits.max_metadata_bytes ->
        {:error, :metadata_limit}

      level not in ~w(debug info warning warn error) ->
        {:error, :invalid_level}

      not valid_timestamp?(timestamp) ->
        {:error, :invalid_timestamp}

      true ->
        normalized = %{
          "timestamp" => timestamp,
          "level" => if(level == "warn", do: "warning", else: level),
          "message" => message,
          "metadata" => metadata
        }

        encoded = Jason.encode!(normalized)

        if byte_size(encoded) <= limits.max_event_bytes and
             byte_size(@prefix) + byte_size(encoded) + byte_size(@suffix) <=
               limits.max_request_bytes, do: {:ok, encoded}, else: {:error, :event_limit}
    end
  rescue
    _ -> {:error, :encoding_failed}
  end

  defp normalize_and_encode(_), do: {:error, :invalid_event}

  defp reserve(bytes) do
    case :persistent_term.get(@admission_key, nil) do
      {ref, limits} -> reserve_cas(ref, bytes, limits)
      nil -> {:error, :not_running}
    end
  end

  defp reserve_cas(ref, bytes, limits) do
    current = :atomics.get(ref, 1)
    {count, used} = unpack(current)

    if count >= limits.max_admitted_events or used + bytes > limits.max_admitted_bytes do
      {:error, :admission_full}
    else
      next = pack(count + 1, used + bytes)

      case :atomics.compare_exchange(ref, 1, current, next) do
        :ok -> :ok
        _actual -> reserve_cas(ref, bytes, limits)
      end
    end
  end

  defp release(events) do
    bytes = Enum.reduce(events, 0, &(byte_size(&1) + &2))
    {ref, _limits} = :persistent_term.get(@admission_key)
    release_cas(ref, length(events), bytes)
  end

  defp release_cas(ref, count, bytes) do
    current = :atomics.get(ref, 1)
    {old_count, old_bytes} = unpack(current)
    next = pack(max(old_count - count, 0), max(old_bytes - bytes, 0))

    case :atomics.compare_exchange(ref, 1, current, next) do
      :ok -> :ok
      _actual -> release_cas(ref, count, bytes)
    end
  end

  defp pack(count, bytes), do: count * 1_099_511_627_776 + bytes
  defp unpack(value), do: {div(value, 1_099_511_627_776), rem(value, 1_099_511_627_776)}

  defp warn_drop(reason) do
    case :persistent_term.get(@admission_key, nil) do
      {ref, _} ->
        now = System.system_time(:millisecond)
        last = :atomics.get(ref, 2)

        if now - last >= 60_000 and :atomics.compare_exchange(ref, 2, last, now) == :ok,
          do: IO.warn("[WhisperLogs.Shipper] dropped log event: #{inspect(reason)}")

      nil ->
        :ok
    end
  end

  defp limits! do
    limits = %{
      max_admitted_events: get(:max_admitted_events, 10_000),
      max_admitted_bytes: get(:max_admitted_bytes, 33_554_432),
      batch_size: get(:batch_size, 100),
      max_request_bytes: get(:max_request_bytes, 7_500_000),
      flush_interval_ms: get(:flush_interval_ms, 1_000),
      max_message_bytes: get(:max_message_bytes, 65_536),
      max_metadata_bytes: get(:max_metadata_bytes, 131_072),
      max_metadata_depth: get(:max_metadata_depth, 8),
      max_event_bytes: get(:max_event_bytes, 262_144),
      receive_timeout: get(:receive_timeout, 10_000)
    }

    Enum.each(limits, fn {key, value} ->
      if not is_integer(value) or value <= 0, do: raise(ArgumentError, "#{key} must be positive")
    end)

    if limits.batch_size > limits.max_admitted_events,
      do: raise(ArgumentError, "batch size exceeds admitted event capacity")

    if limits.max_event_bytes > limits.max_admitted_bytes or
         limits.max_message_bytes > limits.max_event_bytes or
         limits.max_metadata_bytes > limits.max_event_bytes,
       do: raise(ArgumentError, "inconsistent shipper event limits")

    if limits.max_event_bytes + byte_size(@prefix) + byte_size(@suffix) > limits.max_request_bytes,
      do: raise(ArgumentError, "one event cannot fit the request limit")

    limits
  end

  defp collect_bounded_response({:data, data}, {request, response}) do
    received = Map.get(response.private, :whisperlogs_received_bytes, 0) + byte_size(data)

    if received > @max_response_bytes do
      response = %{
        response
        | body: "",
          private: Map.put(response.private, :whisperlogs_body_too_large, true)
      }

      {:halt, {request, response}}
    else
      response = %{
        response
        | body: "",
          private: Map.put(response.private, :whisperlogs_received_bytes, received)
      }

      {:cont, {request, response}}
    end
  end

  defp depth(value) when is_map(value),
    do: 1 + Enum.reduce(value, 0, fn {_key, child}, max_depth -> max(max_depth, depth(child)) end)

  defp depth(value) when is_list(value),
    do: 1 + Enum.reduce(value, 0, fn child, max_depth -> max(max_depth, depth(child)) end)

  defp depth(_), do: 0
  defp encoded_size(value), do: value |> Jason.encode_to_iodata!() |> :erlang.iolist_size()
  defp valid_timestamp?(nil), do: true

  defp valid_timestamp?(value) when is_binary(value) do
    match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
  end

  defp valid_timestamp?(_value), do: false

  defp required_string!(key) do
    case get(key) do
      value when is_binary(value) and value != "" ->
        value

      value ->
        raise ArgumentError, "#{key} must be a non-empty string, got: #{inspect(value)}"
    end
  end

  defp get(key, default \\ nil), do: Application.get_env(:whisperlogs_shipper, key, default)

  defp add_handler do
    case :logger.add_handler(:whisperlogs_shipper, WhisperLogs.Shipper.Handler, %{}) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
      error -> error
    end
  end
end
