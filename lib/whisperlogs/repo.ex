defmodule WhisperLogs.Repo do
  @moduledoc """
  Database repository that delegates to SQLite or PostgreSQL at runtime.

  The adapter is determined by the `:db_adapter` config set in `runtime.exs`
  based on whether `DATABASE_URL` is present.
  """

  @doc """
  Returns the active repository implementation.
  """
  def impl do
    if WhisperLogs.DbAdapter.sqlite?() do
      WhisperLogs.Repo.SQLite
    else
      WhisperLogs.Repo.Postgres
    end
  end

  # Query functions
  def all(queryable, opts \\ []), do: impl().all(queryable, opts)

  @doc """
  Fetches all entries matching the given clauses.

  ## Example

      Repo.all_by(User, active: true)
  """
  def all_by(schema, clauses) do
    import Ecto.Query
    from(x in schema, where: ^clauses) |> all()
  end

  def one(queryable, opts \\ []), do: impl().one(queryable, opts)
  def one!(queryable, opts \\ []), do: impl().one!(queryable, opts)
  def exists?(queryable, opts \\ []), do: impl().exists?(queryable, opts)

  # Get functions
  def get(queryable, id, opts \\ []), do: impl().get(queryable, id, opts)
  def get!(queryable, id, opts \\ []), do: impl().get!(queryable, id, opts)
  def get_by(queryable, clauses, opts \\ []), do: impl().get_by(queryable, clauses, opts)
  def get_by!(queryable, clauses, opts \\ []), do: impl().get_by!(queryable, clauses, opts)

  # Insert functions
  def insert(struct_or_changeset, opts \\ []), do: impl().insert(struct_or_changeset, opts)
  def insert!(struct_or_changeset, opts \\ []), do: impl().insert!(struct_or_changeset, opts)

  def insert_all(schema_or_source, entries, opts \\ []),
    do: impl().insert_all(schema_or_source, entries, opts)

  def insert_or_update(changeset, opts \\ []), do: impl().insert_or_update(changeset, opts)
  def insert_or_update!(changeset, opts \\ []), do: impl().insert_or_update!(changeset, opts)

  # Update functions
  def update(changeset, opts \\ []), do: impl().update(changeset, opts)
  def update!(changeset, opts \\ []), do: impl().update!(changeset, opts)
  def update_all(queryable, updates, opts \\ []), do: impl().update_all(queryable, updates, opts)

  # Delete functions
  def delete(struct_or_changeset, opts \\ []), do: impl().delete(struct_or_changeset, opts)
  def delete!(struct_or_changeset, opts \\ []), do: impl().delete!(struct_or_changeset, opts)
  def delete_all(queryable, opts \\ []), do: impl().delete_all(queryable, opts)

  # Aggregate functions
  # aggregate/2 - :count without field
  def aggregate(queryable, :count), do: impl().aggregate(queryable, :count)
  # aggregate/3 - when third arg is a keyword list (opts)
  def aggregate(queryable, aggregate, opts) when is_list(opts),
    do: impl().aggregate(queryable, aggregate, opts)

  # aggregate/3 - when third arg is a field (atom or string)
  def aggregate(queryable, aggregate, field) when is_atom(field) or is_binary(field),
    do: impl().aggregate(queryable, aggregate, field)

  # aggregate/4 - with explicit field and opts
  def aggregate(queryable, aggregate, field, opts),
    do: impl().aggregate(queryable, aggregate, field, opts)

  # Preload
  def preload(structs_or_struct_or_nil, preloads, opts \\ []),
    do: impl().preload(structs_or_struct_or_nil, preloads, opts)

  def reload(struct_or_structs, opts \\ []), do: impl().reload(struct_or_structs, opts)
  def reload!(struct_or_structs, opts \\ []), do: impl().reload!(struct_or_structs, opts)

  # Stream function (must be used within a transaction)
  def stream(queryable, opts \\ []), do: impl().stream(queryable, opts)

  # Transaction functions
  def transaction(fun_or_multi, opts \\ []), do: impl().transaction(fun_or_multi, opts)
  def transact(fun, opts \\ []), do: impl().transact(fun, opts)
  def rollback(value), do: impl().rollback(value)
  def in_transaction?, do: impl().in_transaction?()

  # Query execution
  def query(sql, params \\ [], opts \\ []), do: impl().query(sql, params, opts)
  def query!(sql, params \\ [], opts \\ []), do: impl().query!(sql, params, opts)

  # Checkout
  def checkout(fun, opts \\ []), do: impl().checkout(fun, opts)

  # Config and adapter info (needed for migrations)
  def __adapter__, do: impl().__adapter__()
  def config, do: impl().config()
  def default_options(_operation), do: []
  def get_dynamic_repo, do: impl().get_dynamic_repo()
  def put_dynamic_repo(dynamic), do: impl().put_dynamic_repo(dynamic)

  # Lifecycle functions (for Ecto.Migrator compatibility)
  def start_link(opts \\ []), do: impl().start_link(opts)
  def stop(timeout \\ 5000), do: impl().stop(timeout)
  def child_spec(opts), do: impl().child_spec(opts)
end
