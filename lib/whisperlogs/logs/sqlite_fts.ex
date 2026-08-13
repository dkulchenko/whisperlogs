defmodule WhisperLogs.Logs.SqliteFts do
  @moduledoc false

  import Ecto.Query

  require Logger

  alias WhisperLogs.DbAdapter
  alias WhisperLogs.Logs.VolumeRollups
  alias WhisperLogs.Repo

  @candidate_cap 25_000
  @ordered_scan_limit 50_000

  def maybe_prefilter(query, tokens, from, to) do
    case strategy(tokens, from, to) do
      {:fts, match_query} ->
        where(
          query,
          [l],
          fragment(
            "? IN (SELECT rowid FROM logs_fts WHERE logs_fts MATCH ?)",
            l.id,
            ^match_query
          )
        )

      :scan ->
        query
    end
  end

  def strategy(tokens, from, to) do
    with true <- DbAdapter.sqlite?(),
         {:ok, match_query} <- match_query(tokens),
         estimated when estimated > @ordered_scan_limit <-
           VolumeRollups.estimated_count(from, to),
         count when count <= @candidate_cap <- candidate_count(match_query) do
      {:fts, match_query}
    else
      _reason -> :scan
    end
  rescue
    error ->
      Logger.warning(
        "SQLite FTS prefilter unavailable; using ordered scan: #{Exception.message(error)}"
      )

      :scan
  end

  defp candidate_count(match_query) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*)
        FROM (
          SELECT rowid
          FROM logs_fts
          WHERE logs_fts MATCH ?
          LIMIT ?
        )
        """,
        [match_query, @candidate_cap + 1],
        timeout: 5_000
      )

    count
  end

  defp match_query(tokens) do
    trigrams =
      tokens
      |> Enum.flat_map(&positive_text/1)
      |> Enum.flat_map(&trigrams/1)
      |> Enum.uniq()

    case trigrams do
      [] -> :error
      trigrams -> {:ok, Enum.map_join(trigrams, " AND ", &quote_token/1)}
    end
  end

  defp positive_text({:term, term}), do: [term]
  defp positive_text({:phrase, phrase}), do: [phrase]
  defp positive_text(_token), do: []

  defp trigrams(value) do
    codepoints = String.codepoints(value)

    if length(codepoints) < 3 do
      []
    else
      codepoints
      |> Enum.chunk_every(3, 1, :discard)
      |> Enum.map(&Enum.join/1)
    end
  end

  defp quote_token(token), do: ~s("#{String.replace(token, ~s("), ~s(""))}")
end
