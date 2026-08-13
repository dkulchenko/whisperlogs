defmodule WhisperLogs.Logs.VolumeRollups do
  @moduledoc """
  Maintains persisted UTC hour and day volume buckets for stored logs.
  """

  import Ecto.Query, warn: false

  alias WhisperLogs.DbAdapter
  alias WhisperLogs.Logs.{Log, LogVolumeRollup}
  alias WhisperLogs.Repo

  @granularities ~w(hour day)

  def increment_batch!(logs, observed_at) when is_list(logs) and logs != [] do
    ids = Enum.map(logs, & &1.id)
    log_count = length(ids)
    bytes = bytes_for_query(where(Log, [l], l.id in ^ids))

    rows = [
      rollup_row("hour", bucket_start(observed_at, :hour), log_count, bytes),
      rollup_row("day", bucket_start(observed_at, :day), log_count, bytes)
    ]

    Repo.insert_all(LogVolumeRollup, rows,
      on_conflict: [inc: [log_count: log_count, byte_count: bytes]],
      conflict_target: [:granularity, :bucket_start]
    )

    :ok
  end

  def increment_batch!([], _observed_at), do: :ok

  def list("hour", hours) when is_integer(hours) and hours > 0 do
    cutoff = DateTime.utc_now() |> DateTime.add(-(hours - 1), :hour) |> bucket_start(:hour)
    list_since("hour", cutoff)
  end

  def list("day", days) when is_integer(days) and days > 0 do
    cutoff = DateTime.utc_now() |> DateTime.add(-(days - 1), :day) |> bucket_start(:day)
    list_since("day", cutoff)
  end

  def list(granularity, _count) when granularity in @granularities, do: []

  def totals do
    {count, bytes} =
      LogVolumeRollup
      |> where([r], r.granularity == "day")
      |> select([r], {coalesce(sum(r.log_count), 0), coalesce(sum(r.byte_count), 0)})
      |> Repo.one()

    {to_integer(count), to_integer(bytes)}
  end

  def reconcile_after_delete!(%DateTime{} = cutoff) do
    Enum.each([:hour, :day], fn granularity ->
      start = bucket_start(cutoff, granularity)
      finish = DateTime.add(start, 1, granularity)
      name = Atom.to_string(granularity)

      LogVolumeRollup
      |> where([r], r.granularity == ^name and r.bucket_start < ^start)
      |> Repo.delete_all()

      query = where(Log, [l], l.inserted_at >= ^start and l.inserted_at < ^finish)
      {count, bytes} = count_and_bytes(query)

      if count == 0 do
        LogVolumeRollup
        |> where([r], r.granularity == ^name and r.bucket_start == ^start)
        |> Repo.delete_all()
      else
        Repo.insert_all(
          LogVolumeRollup,
          [rollup_row(name, start, count, bytes)],
          on_conflict: {:replace, [:log_count, :byte_count]},
          conflict_target: [:granularity, :bucket_start]
        )
      end
    end)

    :ok
  end

  def rebuild!(repo \\ Repo) do
    repo.delete_all(LogVolumeRollup)

    repo.query!("""
    INSERT INTO log_volume_rollups (granularity, bucket_start, log_count, byte_count)
    SELECT 'hour',
           #{bucket_sql("inserted_at", :hour)},
           COUNT(id),
           SUM(#{byte_size_sql()})
    FROM logs
    GROUP BY #{bucket_sql("inserted_at", :hour)}
    """)

    repo.query!("""
    INSERT INTO log_volume_rollups (granularity, bucket_start, log_count, byte_count)
    SELECT 'day',
           #{bucket_sql("bucket_start", :day)},
           SUM(log_count),
           SUM(byte_count)
    FROM log_volume_rollups
    WHERE granularity = 'hour'
    GROUP BY #{bucket_sql("bucket_start", :day)}
    """)

    :ok
  end

  defp list_since(granularity, cutoff) do
    LogVolumeRollup
    |> where([r], r.granularity == ^granularity and r.bucket_start >= ^cutoff)
    |> order_by([r], asc: r.bucket_start)
    |> select([r], {r.bucket_start, r.log_count, r.byte_count})
    |> Repo.all()
  end

  defp bytes_for_query(query) do
    {_count, bytes} = count_and_bytes(query)
    bytes
  end

  defp count_and_bytes(query) do
    volume_select = DbAdapter.volume_select_total()

    case query |> select([l], ^volume_select) |> Repo.one() do
      nil -> {0, 0}
      %{count: nil, bytes: nil} -> {0, 0}
      %{count: count, bytes: bytes} -> {count, bytes || 0}
    end
  end

  defp rollup_row(granularity, bucket_start, log_count, byte_count) do
    %{
      granularity: granularity,
      bucket_start: bucket_start,
      log_count: log_count,
      byte_count: byte_count
    }
  end

  defp bucket_start(%DateTime{} = datetime, :hour) do
    %{datetime | minute: 0, second: 0, microsecond: {0, 6}}
  end

  defp bucket_start(%DateTime{} = datetime, :day) do
    %{datetime | hour: 0, minute: 0, second: 0, microsecond: {0, 6}}
  end

  defp bucket_sql(column, granularity) do
    if DbAdapter.sqlite?() do
      format =
        if granularity == :hour,
          do: "%Y-%m-%dT%H:00:00.000000Z",
          else: "%Y-%m-%dT00:00:00.000000Z"

      "strftime('#{format}', #{column})"
    else
      "date_trunc('#{granularity}', #{column})"
    end
  end

  defp byte_size_sql do
    if DbAdapter.sqlite?() do
      "length(CAST(message AS BLOB)) + length(CAST(coalesce(json(metadata), '{}') AS BLOB))"
    else
      "octet_length(message) + octet_length(coalesce(metadata::text, '{}'))"
    end
  end

  defp to_integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp to_integer(value) when is_integer(value), do: value
end
