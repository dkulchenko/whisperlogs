defmodule WhisperLogs.Syslog.Listener do
  @moduledoc "A bounded UDP/TCP/TLS listener for one persisted source policy."
  use GenServer
  require Logger
  import Bitwise

  alias WhisperLogs.Logs
  alias WhisperLogs.Syslog.{Connection, Limits, Parser}

  defstruct [
    :source_id,
    :source_name,
    :port,
    :transport,
    :admission_mode,
    :allowed_hosts,
    :tls_framing,
    :tls_client_identities,
    :udp_socket,
    :stream_listener,
    :acceptor,
    :ingest_fun,
    queue: :queue.new(),
    outstanding: 0,
    connections: MapSet.new(),
    ingest_tasks: %{},
    policy_generation: 0,
    udp_armed?: false
  ]

  def start_link(opts) do
    source = Keyword.fetch!(opts, :source)
    ingest_fun = Keyword.get(opts, :ingest_fun, &ingest_frame/2)
    GenServer.start_link(__MODULE__, {source, ingest_fun}, name: via(source.id))
  end

  defp via(id), do: {:via, Registry, {WhisperLogs.Syslog.Registry, id}}

  @impl true
  def init({source, ingest_fun}) do
    # Cleanup owns queue reservations and detached task/connection children, so
    # normal supervisor shutdown must run terminate/2.
    Process.flag(:trap_exit, true)
    state = policy(%__MODULE__{ingest_fun: ingest_fun}, source)

    case open_sockets(state) do
      {:ok, state} -> {:ok, arm_udp(state)}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:replace_policy, source}, _from, state) do
    # Admission and TLS identity are established at connection creation. Close
    # every established stream synchronously so removed hosts/fingerprints cannot
    # retain authorization until their idle timeout.
    Enum.each(state.connections, fn pid ->
      _ = DynamicSupervisor.terminate_child(WhisperLogs.Syslog.ConnectionSupervisor, pid)
    end)

    next_state = %{
      state
      | connections: MapSet.new(),
        policy_generation: state.policy_generation + 1
    }

    {:reply, :ok, policy(next_state, source)}
  end

  def handle_call({:admit_connection, ip}, _from, state) do
    max = WhisperLogs.Config.syslog_limits().max_connections_per_source

    if allowed?(ip, state) and MapSet.size(state.connections) < max do
      opts = [
        listener: self(),
        identities: state.tls_client_identities,
        framing: state.tls_framing,
        policy_generation: state.policy_generation
      ]

      {:reply, {:ok, opts}, state}
    else
      {:reply, {:error, :connection_rejected}, state}
    end
  end

  def handle_call({:frame, frame}, _from, state) do
    case enqueue(frame, state) do
      {:ok, state} -> {:reply, :ok, dispatch(state)}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:udp, socket, ip, _port, frame}, %{udp_socket: socket} = state) do
    state = %{state | udp_armed?: false}

    state =
      if allowed?(ip, state) do
        case enqueue(frame, state) do
          {:ok, next} ->
            dispatch(next)

          {:error, _reason, next} ->
            Process.send_after(self(), :retry_udp, 100)
            next
        end
      else
        arm_udp(state)
      end

    {:noreply, state}
  end

  def handle_info({:connection_started, pid, generation}, state) do
    if generation == state.policy_generation do
      Process.monitor(pid)
      {:noreply, %{state | connections: MapSet.put(state.connections, pid)}}
    else
      _ = DynamicSupervisor.terminate_child(WhisperLogs.Syslog.ConnectionSupervisor, pid)
      {:noreply, state}
    end
  end

  def handle_info(:retry_udp, state), do: {:noreply, arm_udp(state)}

  def handle_info({:DOWN, monitor_ref, :process, pid, reason}, state) do
    case Enum.find(state.ingest_tasks, fn {_work_ref, {ref, _pid}} -> ref == monitor_ref end) do
      {work_ref, _monitor} ->
        if reason != :normal do
          Logger.warning("Syslog ingest worker exited: #{inspect(reason)}")
        end

        {:noreply, finish_ingest(state, work_ref, demonitor?: false)}

      nil ->
        {:noreply, %{state | connections: MapSet.delete(state.connections, pid)}}
    end
  end

  def handle_info({:ingest_done, work_ref, result}, state) do
    if match?({:error, _}, result),
      do: Logger.warning("Syslog ingest rejected: #{inspect(result)}")

    {:noreply, finish_ingest(state, work_ref)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp enqueue(frame, state) do
    limits = WhisperLogs.Config.syslog_limits()

    cond do
      state.outstanding >= limits.max_queued_per_source ->
        {:error, :busy, state}

      not is_binary(frame) or byte_size(frame) > limits.max_frame_bytes ->
        {:error, :invalid_frame, arm_udp(state)}

      not String.valid?(frame) or :binary.match(frame, <<0>>) != :nomatch ->
        {:error, :invalid_frame, arm_udp(state)}

      true ->
        case Limits.reserve_queue() do
          :ok ->
            {:ok,
             %{state | queue: :queue.in(frame, state.queue), outstanding: state.outstanding + 1}}

          {:error, _} ->
            {:error, :busy, state}
        end
    end
  end

  defp dispatch(state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, frame}, queue} ->
        owner = self()
        ref = make_ref()
        source = state.source_name
        ingest_fun = state.ingest_fun

        case Task.Supervisor.start_child(WhisperLogs.Syslog.IngestSupervisor, fn ->
               result =
                 try do
                   ingest_fun.(source, frame)
                 rescue
                   error -> {:error, {:ingest_exception, Exception.message(error)}}
                 end

               send(owner, {:ingest_done, ref, result})
             end) do
          {:ok, pid} ->
            monitor_ref = Process.monitor(pid)

            state
            |> Map.put(:queue, queue)
            |> Map.update!(:ingest_tasks, &Map.put(&1, ref, {monitor_ref, pid}))
            |> dispatch()

          {:error, :max_children} ->
            state
        end
    end
  end

  defp finish_ingest(state, work_ref, opts \\ []) do
    case Map.pop(state.ingest_tasks, work_ref) do
      {nil, _tasks} ->
        state

      {{monitor_ref, _pid}, tasks} ->
        if Keyword.get(opts, :demonitor?, true), do: Process.demonitor(monitor_ref, [:flush])
        Limits.release_queue()

        %{state | ingest_tasks: tasks, outstanding: max(state.outstanding - 1, 0)}
        |> dispatch()
        |> arm_udp()
    end
  end

  defp ingest_frame(source, frame) do
    with {:ok, event} <- Parser.parse(frame), do: Logs.insert_batch(source, [event])
  end

  defp open_sockets(state) do
    with {:ok, state} <- open_udp(state), {:ok, state} <- open_stream(state), do: {:ok, state}
  end

  defp open_udp(%{transport: transport, port: port} = state) when transport in ["udp", "both"] do
    case :gen_udp.open(port, [:binary, active: false, reuseaddr: true]) do
      {:ok, socket} -> {:ok, %{state | udp_socket: socket}}
      {:error, reason} -> {:error, {:udp_listen, reason}}
    end
  end

  defp open_udp(state), do: {:ok, state}

  defp open_stream(%{transport: transport} = state) when transport in ["tcp", "both", "tls"] do
    packet = if transport == "tls" and state.tls_framing == "octet_counted", do: :raw, else: :line

    options = [
      :binary,
      active: false,
      reuseaddr: true,
      packet: packet,
      packet_size: WhisperLogs.Config.syslog_limits().max_frame_bytes
    ]

    result =
      if transport == "tls" do
        :ssl.listen(state.port, options ++ tls_options())
      else
        :gen_tcp.listen(state.port, options)
      end

    case result do
      {:ok, listener} ->
        owner = self()
        kind = if transport == "tls", do: :tls, else: :tcp
        acceptor = spawn_link(fn -> accept_loop(owner, listener, kind) end)
        {:ok, %{state | stream_listener: listener, acceptor: acceptor}}

      {:error, reason} ->
        if state.udp_socket, do: :gen_udp.close(state.udp_socket)
        {:error, {:stream_listen, reason}}
    end
  end

  defp open_stream(state), do: {:ok, state}

  defp accept_loop(listener_pid, socket, kind) do
    accept = if kind == :tls, do: :ssl.transport_accept(socket), else: :gen_tcp.accept(socket)

    case accept do
      {:ok, client} ->
        peer = if kind == :tls, do: :ssl.peername(client), else: :inet.peername(client)

        case peer do
          {:ok, {ip, _port}} -> start_connection(listener_pid, client, kind, ip)
          _ -> close(kind, client)
        end

        accept_loop(listener_pid, socket, kind)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("Syslog accept failed: #{inspect(reason)}")
    end
  end

  defp start_connection(listener, socket, kind, ip) do
    with {:ok, policy} <- GenServer.call(listener, {:admit_connection, ip}),
         generation = Keyword.fetch!(policy, :policy_generation),
         spec <-
           {Connection,
            Keyword.merge(policy, socket: socket, transport: kind, handshaken: kind != :tls)},
         {:ok, pid} <-
           DynamicSupervisor.start_child(WhisperLogs.Syslog.ConnectionSupervisor, spec),
         :ok <- controlling_process(kind, socket, pid) do
      send(listener, {:connection_started, pid, generation})
      Connection.activate(pid)
    else
      _ -> close(kind, socket)
    end
  end

  defp controlling_process(:tls, socket, pid), do: :ssl.controlling_process(socket, pid)
  defp controlling_process(:tcp, socket, pid), do: :gen_tcp.controlling_process(socket, pid)
  defp close(:tls, socket), do: :ssl.close(socket)
  defp close(:tcp, socket), do: :gen_tcp.close(socket)

  defp arm_udp(%{udp_socket: nil} = state), do: state
  defp arm_udp(%{udp_armed?: true} = state), do: state

  defp arm_udp(state) do
    :ok = :inet.setopts(state.udp_socket, active: :once)
    %{state | udp_armed?: true}
  end

  defp policy(state, source) do
    %{
      state
      | source_id: source.id,
        source_name: source.source,
        port: source.port,
        transport: source.transport,
        admission_mode: source.admission_mode,
        allowed_hosts: source.allowed_hosts || [],
        tls_framing: source.tls_framing,
        tls_client_identities: source.tls_client_identities || []
    }
  end

  defp allowed?(_ip, %{admission_mode: "any"}), do: true
  defp allowed?(_ip, %{allowed_hosts: []}), do: false
  defp allowed?(ip, state), do: Enum.any?(state.allowed_hosts, &network_contains?(&1, ip))

  defp network_contains?(network, ip) do
    [address | prefix] = String.split(network, "/", parts: 2)

    with {:ok, base} <- :inet.parse_address(String.to_charlist(address)),
         true <- tuple_size(base) == tuple_size(ip) do
      bits = if tuple_size(ip) == 4, do: 32, else: 128

      prefix =
        case prefix do
          [] -> bits
          [value] -> String.to_integer(value)
        end

      shift = bits - prefix
      address_integer(base) >>> shift == address_integer(ip) >>> shift
    else
      _ -> false
    end
  end

  defp address_integer(tuple),
    do:
      tuple
      |> Tuple.to_list()
      |> Enum.reduce(0, fn part, acc ->
        (acc <<< if(tuple_size(tuple) == 4, do: 8, else: 16)) + part
      end)

  defp tls_options do
    cert = System.fetch_env!("WHISPERLOGS_SYSLOG_TLS_CERT_FILE")
    key = System.fetch_env!("WHISPERLOGS_SYSLOG_TLS_KEY_FILE")
    ca = System.fetch_env!("WHISPERLOGS_SYSLOG_TLS_CLIENT_CA_FILE")

    [
      certfile: String.to_charlist(cert),
      keyfile: String.to_charlist(key),
      cacertfile: String.to_charlist(ca),
      verify: :verify_peer,
      fail_if_no_peer_cert: true,
      versions: [:"tlsv1.2", :"tlsv1.3"]
    ]
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.connections, fn pid ->
      _ = DynamicSupervisor.terminate_child(WhisperLogs.Syslog.ConnectionSupervisor, pid)
    end)

    Enum.each(state.ingest_tasks, fn {_work_ref, {_monitor_ref, pid}} ->
      _ = Task.Supervisor.terminate_child(WhisperLogs.Syslog.IngestSupervisor, pid)
    end)

    # No completion/DOWN messages are processed after terminate/2 begins, so all
    # queued and running reservations still represented by outstanding belong to
    # this listener and are released exactly once here.
    Limits.release_queue(state.outstanding)

    if state.udp_socket, do: :gen_udp.close(state.udp_socket)

    if state.stream_listener,
      do: close(if(state.transport == "tls", do: :tls, else: :tcp), state.stream_listener)

    :ok
  end
end
