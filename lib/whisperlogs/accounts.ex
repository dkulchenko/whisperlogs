defmodule WhisperLogs.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias WhisperLogs.Repo

  alias WhisperLogs.Accounts.{Source, User, UserToken, UserNotifier}
  alias WhisperLogs.SourceCache

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

  Registration is allowed if:
  - Config `:allow_public` is true, OR
  - No users exist yet (first user setup)
  """
  def registration_allowed? do
    config = Application.get_env(:whisperlogs, :registration, [])
    allow_public = Keyword.get(config, :allow_public, false)

    allow_public || Repo.aggregate(User, :count) == 0
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
  def register_user(attrs) do
    is_first_user = Repo.aggregate(User, :count) == 0

    %User{}
    |> User.registration_changeset(attrs)
    |> Ecto.Changeset.put_change(:is_admin, is_first_user)
    |> Ecto.Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
    |> Repo.insert()
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
  def create_http_source(%User{} = user, attrs) do
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
  def create_syslog_source(%User{} = user, attrs) do
    changeset =
      %Source{user_id: user.id}
      |> Source.syslog_changeset(attrs)

    case Repo.insert(changeset) do
      {:ok, source} ->
        # Start the listener
        WhisperLogs.Syslog.Supervisor.start_listener(source)
        {:ok, source}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Lists all active (non-revoked) sources for a user.
  """
  def list_sources(%User{id: user_id}) do
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
    |> where([s], s.type == "syslog" and is_nil(s.revoked_at))
    |> Repo.all()
  end

  @doc """
  Gets a source by ID for a user.
  """
  def get_source(%User{id: user_id}, source_id) do
    Repo.get_by(Source, id: source_id, user_id: user_id)
  end

  @doc """
  Gets a source by raw API token (HTTP sources only).

  Returns `{:ok, source}` if valid and active, `{:error, :invalid_key}` otherwise.

  Results are cached in ETS for 15s to reduce database load during high-volume ingestion.
  """
  def get_source_by_token(key) when is_binary(key) do
    case SourceCache.get_source(key) do
      {:ok, source} ->
        {:ok, source}

      :miss ->
        case fetch_source_from_db(key) do
          {:ok, source} = result ->
            SourceCache.cache_source(key, source)
            result

          error ->
            error
        end
    end
  end

  defp fetch_source_from_db(key) do
    query =
      from s in Source,
        where: s.key == ^key and is_nil(s.revoked_at) and s.type == "http",
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
  def revoke_source(%Source{type: "syslog"} = source) do
    # Stop the listener first
    WhisperLogs.Syslog.Supervisor.stop_listener(source.id)

    source
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  def revoke_source(%Source{} = source) do
    source
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  @doc """
  Updates an HTTP source (name only).
  """
  def update_http_source(%Source{type: "http"} = source, attrs) do
    source
    |> Source.update_http_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates a syslog source.
  Restarts the listener if port or transport changes.
  """
  def update_syslog_source(%Source{type: "syslog"} = source, attrs) do
    old_port = source.port
    old_transport = source.transport

    case source |> Source.update_syslog_changeset(attrs) |> Repo.update() do
      {:ok, updated} ->
        # Restart listener if port or transport changed
        if updated.port != old_port or updated.transport != old_transport do
          WhisperLogs.Syslog.Supervisor.stop_listener(updated.id)
          WhisperLogs.Syslog.Supervisor.start_listener(updated)
        end

        {:ok, updated}

      error ->
        error
    end
  end

  @doc """
  Updates the last_used_at timestamp for a source.
  Called asynchronously from the auth plug.

  Throttled to once per 15s per source to reduce database writes during high-volume ingestion.
  """
  def touch_source(%Source{id: id}) do
    if SourceCache.should_touch?(id) do
      SourceCache.mark_touched(id)

      from(s in Source, where: s.id == ^id)
      |> Repo.update_all(set: [last_used_at: DateTime.utc_now(:second)])
    else
      :ok
    end
  end

  @doc """
  Returns the next available port for syslog sources.
  Starts from base_port and finds the first unused port.
  """
  def next_available_syslog_port(base_port \\ 10514) do
    used_ports =
      Source
      |> where([s], s.type == "syslog" and is_nil(s.revoked_at))
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
