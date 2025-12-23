defmodule WhisperLogs.Syslog.Listener do
  @moduledoc """
  GenServer that manages UDP/TCP syslog listeners for a specific source.

  Each source gets its own listener process that opens sockets on the
  configured port and parses incoming syslog messages.
  """
  use GenServer

  require Logger

  alias WhisperLogs.Logs
  alias WhisperLogs.Syslog.Parser

  defstruct [
    :source_id,
    :source_name,
    :port,
    :transport,
    :allowed_hosts,
    :auto_register_hosts,
    :udp_socket,
    :tcp_listener,
    tcp_acceptor_pid: nil
  ]

  @doc """
  Starts a syslog listener for the given source.
  """
  def start_link(opts) do
    source = Keyword.fetch!(opts, :source)
    GenServer.start_link(__MODULE__, source, name: via_tuple(source.id))
  end

  @doc """
  Stops a syslog listener for the given source ID.
  """
  def stop(source_id) do
    GenServer.stop(via_tuple(source_id))
  end

  defp via_tuple(source_id) do
    {:via, Registry, {WhisperLogs.Syslog.Registry, source_id}}
  end

  @impl true
  def init(source) do
    state = %__MODULE__{
      source_id: source.id,
      source_name: source.source,
      port: source.port,
      transport: source.transport,
      allowed_hosts: source.allowed_hosts || [],
      auto_register_hosts: source.auto_register_hosts
    }

    state = start_listeners(state)
    Logger.info("Syslog listener started for source #{state.source_name} on port #{state.port}")
    {:ok, state}
  end

  defp start_listeners(state) do
    state
    |> maybe_start_udp()
    |> maybe_start_tcp()
  end

  defp maybe_start_udp(%{transport: transport, port: port} = state)
       when transport in ["udp", "both"] do
    case :gen_udp.open(port, [:binary, active: true, reuseaddr: true]) do
      {:ok, socket} ->
        Logger.debug("UDP listener started on port #{port}")
        %{state | udp_socket: socket}

      {:error, reason} ->
        Logger.error("Failed to start UDP listener on port #{port}: #{inspect(reason)}")
        state
    end
  end

  defp maybe_start_udp(state), do: state

  defp maybe_start_tcp(%{transport: transport, port: port} = state)
       when transport in ["tcp", "both"] do
    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, packet: :line]) do
      {:ok, listener} ->
        Logger.debug("TCP listener started on port #{port}")
        # Start acceptor process
        pid = spawn_link(fn -> accept_loop(listener, state) end)
        %{state | tcp_listener: listener, tcp_acceptor_pid: pid}

      {:error, reason} ->
        Logger.error("Failed to start TCP listener on port #{port}: #{inspect(reason)}")
        state
    end
  end

  defp maybe_start_tcp(state), do: state

  defp accept_loop(listener, state) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        spawn(fn -> handle_tcp_connection(socket, state) end)
        accept_loop(listener, state)

      {:error, :closed} ->
        Logger.debug("TCP listener closed for source #{state.source_name}")
        :ok

      {:error, reason} ->
        Logger.error("TCP accept error: #{inspect(reason)}")
        accept_loop(listener, state)
    end
  end

  defp handle_tcp_connection(socket, state) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        {:ok, {ip, _port}} = :inet.peername(socket)

        if host_allowed?(ip, state) do
          process_message(data, state)
        end

        handle_tcp_connection(socket, state)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning("TCP connection error: #{inspect(reason)}")
    end
  end

  @impl true
  def handle_info({:udp, _socket, ip, _port, data}, state) do
    if host_allowed?(ip, state) do
      process_message(data, state)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp process_message(data, state) do
    case Parser.parse(data) do
      {:ok, log} ->
        Logs.insert_batch(state.source_name, [log])

      {:error, reason} ->
        Logger.warning("Failed to parse syslog message: #{inspect(reason)} - #{inspect(data)}")
    end
  end

  defp host_allowed?(_ip, %{allowed_hosts: []}), do: true
  defp host_allowed?(_ip, %{auto_register_hosts: true}), do: true

  defp host_allowed?(ip, %{allowed_hosts: hosts}) do
    ip_str = ip |> Tuple.to_list() |> Enum.join(".")
    ip_str in hosts
  end

  @impl true
  def terminate(_reason, state) do
    if state.udp_socket, do: :gen_udp.close(state.udp_socket)
    if state.tcp_listener, do: :gen_tcp.close(state.tcp_listener)
    Logger.info("Syslog listener stopped for source #{state.source_name}")
    :ok
  end
end
