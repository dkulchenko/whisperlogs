defmodule WhisperLogs.MigrationHelpers do
  @moduledoc """
  Helper functions for database-agnostic migrations.

  Use these helpers to conditionally execute PostgreSQL-specific
  or SQLite-specific migration code.

  ## Example

      import WhisperLogs.MigrationHelpers

      def up do
        if postgres?() do
          execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"
        end
      end
  """

  @doc """
  Returns true if using PostgreSQL adapter.
  """
  defdelegate postgres?, to: WhisperLogs.DbAdapter

  @doc """
  Returns true if using SQLite adapter.
  """
  defdelegate sqlite?, to: WhisperLogs.DbAdapter
end
