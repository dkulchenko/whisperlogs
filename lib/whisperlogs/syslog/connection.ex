defmodule WhisperLogs.Syslog.Connection do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def activate(pid), do: GenServer.cast(pid, :activate)

  def child_spec(opts) do
    %{id: {__MODULE__, make_ref()}, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}

  @impl true
  def handle_cast(:activate, state) do
    send(self(), :read)
    {:noreply, state}
  end

  @impl true
  def handle_info(:read, %{transport: :tls, handshaken: false} = state) do
    timeout = WhisperLogs.Config.syslog_limits().tls_handshake_timeout_ms

    case :ssl.handshake(state.socket, timeout) do
      {:ok, socket} ->
        if identity_allowed?(socket, state.identities) do
          send(self(), :read)
          {:noreply, %{state | socket: socket, handshaken: true}}
        else
          {:stop, :unauthorized_client_certificate, state}
        end

      {:error, reason} ->
        {:stop, {:tls_handshake, reason}, state}
    end
  end

  def handle_info(:read, state) do
    case read_frame(state) do
      {:ok, frame} ->
        case GenServer.call(state.listener, {:frame, frame}, :infinity) do
          :ok -> send(self(), :read)
          {:error, :busy} -> Process.send_after(self(), {:retry_frame, frame}, 100)
          {:error, _reason} -> send(self(), :read)
        end

        {:noreply, state}

      {:error, reason} when reason in [:closed, :timeout] ->
        {:stop, :normal, state}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  def handle_info({:retry_frame, frame}, state) do
    case GenServer.call(state.listener, {:frame, frame}, :infinity) do
      :ok -> send(self(), :read)
      {:error, :busy} -> Process.send_after(self(), {:retry_frame, frame}, 100)
      {:error, _reason} -> send(self(), :read)
    end

    {:noreply, state}
  end

  defp read_frame(%{transport: :tcp} = state), do: recv_line(:gen_tcp, state.socket)
  defp read_frame(%{framing: "newline"} = state), do: recv_line(:ssl, state.socket)
  defp read_frame(state), do: recv_octets(state.socket)

  defp recv_line(module, socket) do
    max = WhisperLogs.Config.syslog_limits().max_frame_bytes

    case recv(module, socket, 0) do
      {:ok, data} when byte_size(data) <= max -> {:ok, String.trim_trailing(data, "\n")}
      {:ok, _data} -> {:error, :frame_too_large}
      error -> error
    end
  end

  defp recv_octets(socket) do
    with {:ok, first} <- :ssl.recv(socket, 1, idle_timeout()),
         {:ok, digits} <- read_length(socket, first, ""),
         {length, ""} <- Integer.parse(digits),
         true <- length <= WhisperLogs.Config.syslog_limits().max_frame_bytes,
         {:ok, frame} <- :ssl.recv(socket, length, idle_timeout()) do
      {:ok, frame}
    else
      false -> {:error, :frame_too_large}
      _ -> {:error, :invalid_octet_framing}
    end
  end

  defp read_length(_socket, " ", ""), do: {:error, :invalid_octet_framing}
  defp read_length(_socket, " ", digits), do: {:ok, digits}

  defp read_length(socket, digit, digits)
       when digit >= "0" and digit <= "9" and byte_size(digits) < 10 do
    case :ssl.recv(socket, 1, idle_timeout()) do
      {:ok, next} -> read_length(socket, next, digits <> digit)
      error -> error
    end
  end

  defp read_length(_socket, _digit, _digits), do: {:error, :invalid_octet_framing}

  defp recv(:gen_tcp, socket, length), do: :gen_tcp.recv(socket, length, idle_timeout())
  defp recv(:ssl, socket, length), do: :ssl.recv(socket, length, idle_timeout())
  defp idle_timeout, do: WhisperLogs.Config.syslog_limits().idle_timeout_ms

  defp identity_allowed?(socket, identities) do
    with {:ok, der} <- :ssl.peercert(socket) do
      cert = fingerprint(der)
      spki = spki_fingerprint(der)
      Enum.any?(identities, &(&1 in ["cert-sha256:#{cert}", "spki-sha256:#{spki}"]))
    else
      _ -> false
    end
  end

  defp fingerprint(der), do: :crypto.hash(:sha256, der) |> Base.encode16(case: :lower)

  defp spki_fingerprint(der) do
    try do
      certificate = :public_key.pkix_decode_cert(der, :plain)
      tbs = elem(certificate, 1)
      spki = elem(tbs, 7)
      :public_key.der_encode(:SubjectPublicKeyInfo, spki) |> fingerprint()
    rescue
      _ -> ""
    end
  end

  @impl true
  def terminate(_reason, %{transport: :tls, socket: socket}), do: :ssl.close(socket)
  def terminate(_reason, %{socket: socket}), do: :gen_tcp.close(socket)
end
