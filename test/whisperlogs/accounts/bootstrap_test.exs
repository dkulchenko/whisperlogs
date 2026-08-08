defmodule WhisperLogs.Accounts.BootstrapTest do
  use WhisperLogs.DataCase, async: false

  import WhisperLogs.AccountsFixtures

  alias WhisperLogs.Accounts.{Bootstrap, User}
  alias WhisperLogs.Repo

  @password "correct horse battery staple"

  test "creates exactly one password-bearing initial administrator" do
    assert :ok =
             Bootstrap.run(
               email: "admin@example.com",
               password: @password
             )

    assert [user] = Repo.all(User)
    assert user.email == "admin@example.com"
    assert user.is_admin
    assert User.valid_password?(user, @password)
  end

  test "upgrades only the recognized legacy account in place" do
    legacy =
      Repo.insert!(%User{
        email: "local@localhost",
        is_admin: true
      })

    assert :ok = Bootstrap.run(password: @password)
    assert %User{id: id} = updated = Repo.get!(User, legacy.id)
    assert id == legacy.id
    assert User.valid_password?(updated, @password)
  end

  test "leaves one password-bearing admin and non-admin users unchanged" do
    admin = user_fixture(%{is_admin: true})
    non_admin = user_fixture()

    assert :ok = Bootstrap.run()
    assert Repo.get!(User, admin.id).hashed_password == admin.hashed_password
    refute Repo.get!(User, non_admin.id).is_admin
  end

  test "rejects ambiguous account states" do
    user_fixture()

    assert {:error, {:invalid_bootstrap_state, %{users: 1, admins: 0, remediation: remediation}}} =
             Bootstrap.run(password: @password)

    assert remediation =~ "exactly one password-bearing administrator"
  end

  test "rejects multiple administrators" do
    user_fixture(%{is_admin: true})
    user_fixture(%{is_admin: true})

    assert {:error, {:invalid_bootstrap_state, %{users: 2, admins: 2, remediation: remediation}}} =
             Bootstrap.run()

    assert remediation =~ "restore a backup"
  end

  test "reads one trailing newline from a private regular password file" do
    path = password_file!(@password <> "\n", 0o600)
    assert Bootstrap.read_password_file!(path) == @password
  end

  test "rejects relative, accessible, oversized, and symlink password files" do
    assert_raise RuntimeError, ~r/must be absolute/, fn ->
      Bootstrap.read_password_file!("relative-password")
    end

    accessible = password_file!(@password, 0o640)

    assert_raise RuntimeError, ~r/must not be group\/world accessible/, fn ->
      Bootstrap.read_password_file!(accessible)
    end

    oversized = password_file!(String.duplicate("x", 1_025), 0o600)

    assert_raise RuntimeError, ~r/exceeds 1024 bytes/, fn ->
      Bootstrap.read_password_file!(oversized)
    end

    target = password_file!(@password, 0o600)
    link = target <> "-link"
    :ok = File.ln_s(target, link)
    on_exit(fn -> File.rm(link) end)

    assert_raise RuntimeError, ~r/regular, non-symlink/, fn ->
      Bootstrap.read_password_file!(link)
    end
  end

  defp password_file!(contents, mode) do
    path =
      Path.join(
        System.tmp_dir!(),
        "whisperlogs-password-#{System.unique_integer([:positive])}"
      )

    File.write!(path, contents, [:exclusive])
    File.chmod!(path, mode)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
