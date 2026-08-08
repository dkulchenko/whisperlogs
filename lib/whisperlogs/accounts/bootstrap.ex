defmodule WhisperLogs.Accounts.Bootstrap do
  @moduledoc false

  import Ecto.Query

  alias WhisperLogs.Accounts.User
  alias WhisperLogs.Repo

  @postgres_lock 1_019_000
  @max_password_file_bytes 1_024

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  def start_link(_opts) do
    if Application.get_env(:whisperlogs, :bootstrap, [])[:enabled] == false do
      :ignore
    else
      case run() do
        :ok -> :ignore
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def run(opts \\ []) do
    transaction_opts = if WhisperLogs.DbAdapter.sqlite?(), do: [mode: :immediate], else: []

    case Repo.transaction(fn -> bootstrap_locked(opts) end, transaction_opts) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp bootstrap_locked(opts) do
    if WhisperLogs.DbAdapter.postgres?() do
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [@postgres_lock])
    end

    users = Repo.all(from u in User, order_by: [asc: u.id])
    admins = Enum.filter(users, & &1.is_admin)

    case {users, admins} do
      {[], []} ->
        insert_initial_admin(opts)

      {[%User{email: "local@localhost", is_admin: true, hashed_password: nil} = user], [user]} ->
        set_legacy_password(user, opts)

      {_users, [%User{hashed_password: password}]} when is_binary(password) ->
        :ok

      _other ->
        Repo.rollback(
          {:invalid_bootstrap_state,
           %{
             users: length(users),
             admins: length(admins),
             remediation:
               "restore a backup or explicitly leave exactly one password-bearing administrator before restarting"
           }}
        )
    end
  end

  defp insert_initial_admin(opts) do
    email = Keyword.get(opts, :email) || System.get_env("WHISPERLOGS_BOOTSTRAP_ADMIN_EMAIL")
    password = read_password!(opts)

    %User{}
    |> User.registration_changeset(%{
      "email" => email,
      "password" => password,
      "password_confirmation" => password
    })
    |> Ecto.Changeset.put_change(:is_admin, true)
    |> Repo.insert()
    |> unwrap_or_rollback()
  end

  defp set_legacy_password(user, opts) do
    password = read_password!(opts)

    user
    |> User.password_changeset(%{
      "password" => password,
      "password_confirmation" => password
    })
    |> Repo.update()
    |> unwrap_or_rollback()
  end

  defp unwrap_or_rollback({:ok, _user}), do: :ok

  defp unwrap_or_rollback({:error, changeset}),
    do: Repo.rollback({:invalid_bootstrap_account, changeset})

  defp read_password!(opts) do
    case Keyword.fetch(opts, :password) do
      {:ok, password} when is_binary(password) -> password
      :error -> read_password_file!()
    end
  end

  def read_password_file!(path \\ nil) do
    path =
      path || System.get_env("WHISPERLOGS_BOOTSTRAP_ADMIN_PASSWORD_FILE") ||
        raise "WHISPERLOGS_BOOTSTRAP_ADMIN_PASSWORD_FILE is required for bootstrap"

    if Path.type(path) != :absolute do
      raise "WHISPERLOGS_BOOTSTRAP_ADMIN_PASSWORD_FILE must be absolute"
    end

    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode, size: size}}
      when Bitwise.band(mode, 0o077) == 0 and size <= @max_password_file_bytes ->
        path
        |> File.read!()
        |> trim_one_newline()

      {:ok, %{type: :regular, size: size}} when size > @max_password_file_bytes ->
        raise "bootstrap password file exceeds #{@max_password_file_bytes} bytes"

      {:ok, %{type: :regular}} ->
        raise "bootstrap password file must not be group/world accessible"

      {:ok, _stat} ->
        raise "bootstrap password file must be a regular, non-symlink file"

      {:error, reason} ->
        raise "cannot inspect bootstrap password file: #{inspect(reason)}"
    end
  end

  defp trim_one_newline(value) do
    cond do
      String.ends_with?(value, "\r\n") -> String.slice(value, 0, byte_size(value) - 2)
      String.ends_with?(value, "\n") -> String.slice(value, 0, byte_size(value) - 1)
      true -> value
    end
  end
end
