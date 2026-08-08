defmodule WhisperLogs.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias WhisperLogs.Repo

  alias WhisperLogs.Accounts.{Scope, Source, User, UserToken, UserNotifier}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Returns whether public registration is allowed.

  Registration is allowed only when explicit configuration enables it.
  """
  def registration_allowed? do
    config = Application.get_env(:whisperlogs, :registration, [])
    allow_public = Keyword.get(config, :allow_public, false)

    allow_public
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for user registration.

  See `WhisperLogs.Accounts.User.registration_changeset/3` for a list of supported options.
  """
  def change_user_registration(user, attrs \\ %{}, opts \\ []) do
    User.registration_changeset(user, attrs, opts)
  end

  @doc """
  Registers a user with email and password.

  ## Examples

      iex> register_user(%{email: "user@example.com", password: "valid_password123"})
      {:ok, %User{}}

      iex> register_user(%{email: "invalid"})
      {:error, %Ecto.Changeset{}}

  """
  def register_public_user(%Scope{user: nil}, attrs), do: do_register_public_user(attrs)
  def register_public_user(nil, attrs), do: do_register_public_user(attrs)

  defp do_register_public_user(attrs) do
    Repo.transaction(fn ->
      if registration_allowed?() do
        %User{}
        |> User.registration_changeset(attrs)
        |> Ecto.Changeset.put_change(:is_admin, false)
        |> Repo.insert()
        |> case do
          {:ok, user} -> user
          {:error, changeset} -> Repo.rollback(changeset)
        end
      else
        Repo.rollback(:registration_closed)
      end
    end)
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `WhisperLogs.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `WhisperLogs.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  @doc """
  Deletes expired tokens from the database.
  Used by retention cleanup.

  Token expiry periods:
  - Session tokens: 14 days
  - Magic link tokens: 15 minutes
  - Change email tokens: 7 days
  """
  def delete_expired_tokens do
    now = DateTime.utc_now()

    # Delete expired session tokens (14 days)
    session_cutoff = DateTime.add(now, -14, :day)

    # Delete expired magic link tokens (15 minutes)
    magic_link_cutoff = DateTime.add(now, -15, :minute)

    # Delete expired change email tokens (7 days)
    change_email_cutoff = DateTime.add(now, -7, :day)

    {count, _} =
      UserToken
      |> where(
        [t],
        (t.context == "session" and t.inserted_at < ^session_cutoff) or
          (t.context == "login" and t.inserted_at < ^magic_link_cutoff) or
          (t.context != "session" and t.context != "login" and
             t.inserted_at < ^change_email_cutoff)
      )
      |> Repo.delete_all()

    {count, nil}
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end

  ## Sources (HTTP and Syslog)

  @doc """
  Creates a new HTTP source for a user.
  Generates an API key for authentication.
  """
  def create_http_source(%Scope{user: %User{} = user}, attrs) do
    key = Source.generate_key()

    changeset =
      %Source{user_id: user.id}
      |> Source.http_changeset(attrs)
      |> Ecto.Changeset.put_change(:key, key)

    case Repo.insert(changeset) do
      {:ok, source} -> {:ok, source}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Creates a new syslog source for a user.
  Starts a listener on the specified port after creation.
  """
  def create_syslog_source(%Scope{user: %User{} = user}, attrs) do
    changeset =
      %Source{user_id: user.id}
      |> Source.syslog_changeset(attrs)

    result =
      WhisperLogs.DbAdapter.serialized_transaction(:syslog_sources, fn ->
        enforce_syslog_quota!(user.id)

        case Repo.insert(changeset) do
          {:ok, source} -> source
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, source} ->
        case WhisperLogs.Syslog.Supervisor.start_listener(source) do
          {:ok, _pid} -> {:ok, source}
          {:error, reason} -> {:error, {:listener_start_failed, source, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Lists all active (non-revoked) sources for a user.
  """
  def list_sources(%Scope{user: %User{id: user_id}}) do
    Source
    |> where([s], s.user_id == ^user_id and is_nil(s.revoked_at))
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  @doc """
  Lists all active syslog sources (for startup initialization).
  """
  def list_syslog_sources do
    Source
    |> where([s], s.type == "syslog" and s.enabled and is_nil(s.revoked_at))
    |> Repo.all()
  end

  @doc """
  Gets a source by ID for a user.
  """
  def get_source(%Scope{user: %User{id: user_id}}, source_id) do
    Repo.get_by(Source, id: source_id, user_id: user_id)
  end

  @doc """
  Gets a source by raw API token (HTTP sources only).

  Returns `{:ok, source}` if valid and active, `{:error, :invalid_key}` otherwise.

  The active source is queried directly so revocation takes effect immediately.
  """
  def get_source_by_token(key) when is_binary(key) do
    query =
      from s in Source,
        where: s.key == ^key and s.enabled and is_nil(s.revoked_at) and s.type == "http",
        preload: [:user]

    case Repo.one(query) do
      nil -> {:error, :invalid_key}
      source -> {:ok, source}
    end
  end

  @doc """
  Revokes a source (soft delete).
  Stops the syslog listener if it's a syslog source.
  """
  def revoke_source(%Scope{} = scope, source_id) do
    with %Source{} = source <- get_source(scope, source_id),
         {:ok, source} <-
           source
           |> Ecto.Changeset.change(enabled: false, revoked_at: DateTime.utc_now(:second))
           |> Repo.update() do
      if source.type == "syslog", do: WhisperLogs.Syslog.Supervisor.stop_listener(source.id)
      {:ok, source}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Updates an HTTP source (name only).
  """
  def update_http_source(%Scope{} = scope, source_id, attrs) do
    case get_source(scope, source_id) do
      %Source{type: "http"} = source ->
        source |> Source.update_http_changeset(attrs) |> Repo.update()

      _other ->
        {:error, :not_found}
    end
  end

  @doc """
  Updates a syslog source.
  Restarts the listener if port or transport changes.
  """
  def update_syslog_source(%Scope{} = scope, source_id, attrs) do
    source = get_source(scope, source_id)

    with %Source{type: "syslog"} <- source,
         old_port = source.port,
         old_transport = source.transport,
         {:ok, updated} <- source |> Source.update_syslog_changeset(attrs) |> Repo.update() do
      restart? = updated.port != old_port or updated.transport != old_transport
      restart? = restart? or updated.tls_framing != source.tls_framing

      result =
        cond do
          not updated.enabled ->
            :ok

          restart? ->
            WhisperLogs.Syslog.Supervisor.stop_listener(updated.id)
            start_listener_result(updated)

          true ->
            WhisperLogs.Syslog.Supervisor.replace_policy(updated)
        end

      case result do
        :ok -> {:ok, updated}
        {:error, reason} -> {:error, {:listener_update_failed, updated, reason}}
      end
    else
      nil -> {:error, :not_found}
      %Source{} -> {:error, :not_found}
      error -> error
    end
  end

  def enable_syslog_source(%Scope{user: %User{id: user_id}} = scope, source_id) do
    result =
      WhisperLogs.DbAdapter.serialized_transaction(:syslog_sources, fn ->
        case get_source(scope, source_id) do
          %Source{type: "syslog", enabled: false} = source ->
            enforce_syslog_quota!(user_id)

            source
            |> Source.persisted_syslog_changeset()
            |> Ecto.Changeset.put_change(:enabled, true)
            |> Repo.update()
            |> case do
              {:ok, updated} -> updated
              {:error, changeset} -> Repo.rollback(changeset)
            end

          %Source{type: "syslog", enabled: true} = source ->
            source

          _other ->
            Repo.rollback(:not_found)
        end
      end)

    case result do
      {:ok, updated} ->
        case start_listener_result(updated) do
          :ok -> {:ok, updated}
          {:error, reason} -> {:error, {:listener_start_failed, updated, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def disable_syslog_source(%Scope{} = scope, source_id) do
    result =
      WhisperLogs.DbAdapter.serialized_transaction(:syslog_sources, fn ->
        case get_source(scope, source_id) do
          %Source{type: "syslog"} = source ->
            source
            |> Ecto.Changeset.change(enabled: false)
            |> Repo.update()
            |> case do
              {:ok, updated} -> updated
              {:error, changeset} -> Repo.rollback(changeset)
            end

          _other ->
            Repo.rollback(:not_found)
        end
      end)

    case result do
      {:ok, updated} ->
        WhisperLogs.Syslog.Supervisor.stop_listener(updated.id)
        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp enforce_syslog_quota!(user_id) do
    per_user =
      Repo.aggregate(
        from(s in Source,
          where:
            s.type == "syslog" and s.enabled and is_nil(s.revoked_at) and s.user_id == ^user_id
        ),
        :count
      )

    global =
      Repo.aggregate(
        from(s in Source, where: s.type == "syslog" and s.enabled and is_nil(s.revoked_at)),
        :count
      )

    cond do
      per_user >= 20 -> Repo.rollback(:syslog_user_quota_exceeded)
      global >= 500 -> Repo.rollback(:syslog_global_quota_exceeded)
      true -> :ok
    end
  end

  @doc "Validates enabled syslog rows and their global/per-owner startup quotas."
  def validated_syslog_sources_for_startup do
    sources = list_syslog_sources()

    invalid_ids =
      for source <- sources,
          not Source.persisted_syslog_changeset(source).valid?,
          do: source.id

    over_limit_users =
      sources
      |> Enum.frequencies_by(& &1.user_id)
      |> Enum.filter(fn {_user_id, count} -> count > 20 end)
      |> Enum.map(&elem(&1, 0))

    cond do
      invalid_ids != [] -> {:error, {:invalid_sources, invalid_ids}}
      over_limit_users != [] -> {:error, {:user_quota_exceeded, over_limit_users}}
      length(sources) > 500 -> {:error, {:global_quota_exceeded, length(sources)}}
      true -> {:ok, sources}
    end
  end

  defp start_listener_result(source) do
    case WhisperLogs.Syslog.Supervisor.start_listener(source) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the next available port for syslog sources.
  Starts from base_port and finds the first unused port.
  """
  def next_available_syslog_port(base_port \\ 10514) do
    used_ports =
      Source
      |> where([s], s.type == "syslog" and s.enabled and is_nil(s.revoked_at))
      |> select([s], s.port)
      |> Repo.all()
      |> MapSet.new()

    find_available_port(base_port, used_ports)
  end

  defp find_available_port(port, used_ports) when port < 65535 do
    if MapSet.member?(used_ports, port) do
      find_available_port(port + 1, used_ports)
    else
      port
    end
  end

  defp find_available_port(_port, _used_ports), do: nil
end
