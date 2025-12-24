defmodule WhisperLogs.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `WhisperLogs.Accounts` context.
  """

  import Ecto.Query

  alias WhisperLogs.Accounts
  alias WhisperLogs.Accounts.Scope

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    password = valid_user_password()

    Enum.into(attrs, %{
      email: unique_user_email(),
      password: password,
      password_confirmation: password
    })
  end

  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> valid_user_attributes()
      |> Accounts.register_user()

    user
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    WhisperLogs.Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    WhisperLogs.Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end

  # ===== Source Fixtures =====

  @doc """
  Creates an HTTP source (API key based).

  ## Examples

      http_source_fixture(user)
      http_source_fixture(user, name: "My Source", source: "my-source")
  """
  def http_source_fixture(user \\ nil, attrs \\ []) do
    user = user || user_fixture()
    name = Keyword.get(attrs, :name, "Test HTTP Source")
    source = Keyword.get(attrs, :source, "test-source-#{System.unique_integer([:positive])}")

    {:ok, source_record} =
      Accounts.create_http_source(user, %{
        name: name,
        source: source
      })

    source_record
  end

  @doc """
  Creates a syslog source.

  Note: This will attempt to start a listener, which may fail in tests
  if the port is unavailable. Use high ports (50000+) for test stability.

  ## Examples

      syslog_source_fixture(user)
      syslog_source_fixture(user, port: 50514, transport: "udp")
  """
  def syslog_source_fixture(user \\ nil, attrs \\ []) do
    user = user || user_fixture()
    name = Keyword.get(attrs, :name, "Test Syslog Source")
    source = Keyword.get(attrs, :source, "syslog-source-#{System.unique_integer([:positive])}")
    port = Keyword.get(attrs, :port) || next_test_port()
    transport = Keyword.get(attrs, :transport, "udp")
    auto_register = Keyword.get(attrs, :auto_register_hosts, true)

    {:ok, source_record} =
      Accounts.create_syslog_source(user, %{
        name: name,
        source: source,
        port: port,
        transport: transport,
        auto_register_hosts: auto_register,
        allowed_hosts: Keyword.get(attrs, :allowed_hosts, [])
      })

    source_record
  end

  # Use high ephemeral ports for test stability
  defp next_test_port do
    offset = rem(:erlang.unique_integer([:positive, :monotonic]), 10_000)
    50_000 + offset
  end
end
