defmodule WhisperLogs.Repo.Migrations.AddCompositeIndexesForPerformance do
  use Ecto.Migration

  def change do
    # The most common query pattern is:
    #   WHERE level IN (?) AND timestamp >= ? ORDER BY timestamp DESC, id DESC LIMIT N
    #
    # SQLite can only use one index per table scan. The existing separate indexes
    # on level and timestamp force SQLite to pick one and scan rows for the other.
    # This composite index lets SQLite satisfy level filter + time range + sort order
    # in a single index scan. (SQLite implicitly appends rowid, so id ordering is covered.)
    #
    # This directly fixes the 5-10s lockup when toggling level checkboxes.
    create index(:logs, [:level, :timestamp])

    # The single-column level index is now redundant (covered by the composite)
    drop_if_exists index(:logs, [:level], name: :logs_level_index)
  end
end
