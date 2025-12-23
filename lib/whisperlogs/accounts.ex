defmodule WhisperLogs.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias WhisperLogs.Repo

  alias WhisperLogs.Accounts.{Source, User, UserToken, UserNotifier}

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
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    is_first_user = Repo.aggregate(User, :count) == 0

    %User{}
    |> User.email_changeset(attrs)
    |> Ecto.Changeset.put_change(:is_admin, is_first_user)
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

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
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
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
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
  """
  def get_source_by_token(key) when is_binary(key) do
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
  Updates the last_used_at timestamp for a source.
  Called asynchronously from the auth plug.
  """
  def touch_source(%Source{id: id}) do
    from(s in Source, where: s.id == ^id)
    |> Repo.update_all(set: [last_used_at: DateTime.utc_now(:second)])
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
