defmodule WhisperLogsWeb.Plugs.RuntimeLimitsTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias WhisperLogsWeb.Plugs.{RuntimeBodyReader, RuntimeRequestLimit, RuntimeSession}

  setup do
    old_limits = Application.fetch_env!(:whisperlogs, :receiver_limits)
    old_secure = Application.get_env(:whisperlogs, :secure_cookies)

    Application.put_env(
      :whisperlogs,
      :receiver_limits,
      Map.put(old_limits, :max_request_bytes, 16)
    )

    on_exit(fn ->
      Application.put_env(:whisperlogs, :receiver_limits, old_limits)
      Application.put_env(:whisperlogs, :secure_cookies, old_secure)
    end)

    :ok
  end

  test "accepts the exact transport-byte maximum and rejects the first excess" do
    exact = conn(:post, "/", String.duplicate("a", 16))
    assert {:ok, body, _conn} = RuntimeBodyReader.read_body(exact, [])
    assert byte_size(body) == 16

    excess = conn(:post, "/", String.duplicate("a", 17))
    assert {:more, "", _conn} = RuntimeBodyReader.read_body(excess, [])
  end

  test "rejects non-identity content encoding before reading" do
    encoded =
      conn(:post, "/", "compressed")
      |> put_req_header("content-encoding", "gzip")

    assert {:error, :unsupported_content_encoding} = RuntimeBodyReader.read_body(encoded, [])
  end

  test "rejects oversized and ambiguous content-length headers" do
    oversized =
      conn(:post, "/", "")
      |> put_req_header("content-length", "17")

    assert_raise Plug.Parsers.RequestTooLargeError, fn ->
      RuntimeRequestLimit.call(oversized, [])
    end

    ambiguous = %{oversized | req_headers: [{"content-length", "1"}, {"content-length", "2"}]}

    assert_raise Plug.BadRequestError, ~r/multiple content-length/, fn ->
      RuntimeRequestLimit.call(ambiguous, [])
    end
  end

  test "hosted and loopback sessions use the same signed cookie with different Secure policy" do
    hosted = session_response(true)
    loopback = session_response(false)

    hosted_cookie = get_resp_header(hosted, "set-cookie") |> List.first()
    loopback_cookie = get_resp_header(loopback, "set-cookie") |> List.first()

    assert hosted_cookie =~ "secure"
    assert hosted_cookie =~ "HttpOnly"
    assert hosted_cookie =~ "SameSite=Lax"
    refute loopback_cookie =~ "secure"
    assert loopback_cookie =~ "HttpOnly"
    assert loopback_cookie =~ "SameSite=Lax"
    assert RuntimeSession.verification_options()[:key] == "_whisperlogs_key"
  end

  defp session_response(secure?) do
    Application.put_env(:whisperlogs, :secure_cookies, secure?)

    conn(:get, "/")
    |> Map.put(:secret_key_base, String.duplicate("s", 64))
    |> RuntimeSession.call([])
    |> fetch_session()
    |> put_session(:user_token, "token")
    |> send_resp(200, "ok")
  end
end
