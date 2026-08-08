defmodule WhisperLogs.Accounts.SourcesTest do
  use WhisperLogs.DataCase, async: false

  import WhisperLogs.AccountsFixtures

  alias WhisperLogs.Accounts
  alias WhisperLogs.Accounts.Source
  alias WhisperLogs.Repo

  test "source operations enforce ownership at the context boundary" do
    owner = user_fixture()
    other = user_fixture()
    source = http_source_fixture(owner)
    other_scope = Accounts.Scope.for_user(other)

    assert Accounts.get_source(other_scope, source.id) == nil

    assert {:error, :not_found} =
             Accounts.update_http_source(other_scope, source.id, %{name: "x"})

    assert {:error, :not_found} = Accounts.revoke_source(other_scope, source.id)
  end

  test "syslog changesets normalize networks and enforce typed TLS identities" do
    fingerprint = String.duplicate("a", 64)

    changeset =
      Source.syslog_changeset(%Source{}, %{
        name: "TLS",
        source: "tls",
        port: 6514,
        transport: "tls",
        admission_mode: "allowlist",
        allowed_hosts: [" 127.0.0.1/32 ", "2001:0db8::1/128"],
        tls_framing: "octet_counted",
        tls_client_identities: ["cert-sha256:#{fingerprint}", "spki-sha256:#{fingerprint}"]
      })

    assert changeset.valid?

    assert Ecto.Changeset.get_field(changeset, :allowed_hosts) == [
             "127.0.0.1/32",
             "2001:db8::1/128"
           ]

    duplicate =
      Source.syslog_changeset(%Source{}, %{
        name: "TLS",
        source: "tls",
        port: 6514,
        transport: "tls",
        admission_mode: "allowlist",
        tls_framing: "newline",
        tls_client_identities: ["cert-sha256:#{fingerprint}", "cert-sha256:#{fingerprint}"]
      })

    refute duplicate.valid?
    assert "must not contain duplicates" in errors_on(duplicate).tls_client_identities
  end

  test "failed listener startup leaves the persisted source enabled for visible remediation" do
    user = user_fixture()
    scope = Accounts.Scope.for_user(user)
    {:ok, socket} = :gen_udp.open(0, [:binary])
    {:ok, port} = :inet.port(socket)
    on_exit(fn -> :gen_udp.close(socket) end)

    assert {:error, {:listener_start_failed, source, reason}} =
             Accounts.create_syslog_source(scope, %{
               name: "Conflicted",
               source: "conflicted",
               port: port,
               transport: "udp",
               admission_mode: "any"
             })

    assert inspect(reason) =~ "eaddrinuse"
    assert source.enabled
    assert Repo.get!(Source, source.id).enabled
  end

  test "disable persists before synchronously stopping the listener" do
    user = user_fixture()
    scope = Accounts.Scope.for_user(user)
    port = available_port()

    assert {:ok, source} =
             Accounts.create_syslog_source(scope, %{
               name: "UDP",
               source: "udp",
               port: port,
               transport: "udp",
               admission_mode: "any"
             })

    assert [{pid, _}] = Registry.lookup(WhisperLogs.Syslog.Registry, source.id)
    ref = Process.monitor(pid)
    assert {:ok, disabled} = Accounts.disable_syslog_source(scope, source.id)
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
    refute disabled.enabled
  end

  test "the first per-user syslog quota excess is rejected inside admission" do
    user = user_fixture()
    scope = Accounts.Scope.for_user(user)

    Enum.each(1..20, fn index ->
      Repo.insert!(%Source{
        user_id: user.id,
        name: "Source #{index}",
        source: "source-#{index}",
        type: "syslog",
        port: 20_000 + index,
        transport: "udp",
        admission_mode: "any",
        enabled: true,
        allowed_hosts: [],
        tls_client_identities: []
      })
    end)

    candidate =
      Repo.insert!(%Source{
        user_id: user.id,
        name: "Candidate",
        source: "candidate",
        type: "syslog",
        port: 21_000,
        transport: "udp",
        admission_mode: "any",
        enabled: false,
        allowed_hosts: [],
        tls_client_identities: []
      })

    assert {:error, :syslog_user_quota_exceeded} =
             Accounts.enable_syslog_source(scope, candidate.id)

    refute Repo.get!(Source, candidate.id).enabled
  end

  test "enabling revalidates the complete persisted syslog policy" do
    user = user_fixture()
    scope = Accounts.Scope.for_user(user)

    source =
      Repo.insert!(%Source{
        user_id: user.id,
        name: "Legacy TLS",
        source: "legacy-tls",
        type: "syslog",
        port: available_port(),
        transport: "tls",
        admission_mode: "allowlist",
        enabled: false,
        allowed_hosts: ["127.0.0.1"],
        tls_framing: "newline",
        tls_client_identities: []
      })

    assert {:error, %Ecto.Changeset{} = changeset} =
             Accounts.enable_syslog_source(scope, source.id)

    refute changeset.valid?
    assert "must contain at least one identity" in errors_on(changeset).tls_client_identities
    refute Repo.get!(Source, source.id).enabled
  end

  test "startup validation rejects an enabled invalid persisted policy" do
    user = user_fixture()

    source =
      Repo.insert!(%Source{
        user_id: user.id,
        name: "Invalid TLS",
        source: "invalid-tls",
        type: "syslog",
        port: available_port(),
        transport: "tls",
        admission_mode: "allowlist",
        enabled: true,
        allowed_hosts: ["127.0.0.1"],
        tls_framing: "newline",
        tls_client_identities: []
      })

    assert {:error, {:invalid_sources, [source_id]}} =
             Accounts.validated_syslog_sources_for_startup()

    assert source_id == source.id
  end

  defp available_port do
    {:ok, socket} = :gen_udp.open(0, [:binary])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_udp.close(socket)
    port
  end
end
