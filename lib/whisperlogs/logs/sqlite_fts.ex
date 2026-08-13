defmodule WhisperLogs.Logs.SqliteFts do
  @moduledoc false

  import Ecto.Query

  require Logger

  alias WhisperLogs.DbAdapter
  alias WhisperLogs.Logs.VolumeRollups
  alias WhisperLogs.Repo

  @candidate_cap 25_000
  @ordered_scan_limit 50_000
  @max_exact_regex_expansion 16

  def maybe_prefilter(query, tokens, from, to) do
    case strategy(tokens, from, to) do
      {:fts, match_query} ->
        apply_prefilter(query, match_query, from, to)

      :scan ->
        query
    end
  end

  def strategy(tokens, from, to) do
    with true <- DbAdapter.sqlite?(),
         {:ok, match_query} <- match_query(tokens),
         estimated when estimated > @ordered_scan_limit <-
           VolumeRollups.estimated_count(from, to),
         count when count <= @candidate_cap <- candidate_count(match_query, from, to) do
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

  defp apply_prefilter(query, match_query, nil, nil) do
    where(
      query,
      [l],
      fragment(
        "? IN (SELECT rowid FROM logs_fts WHERE logs_fts MATCH ?)",
        l.id,
        ^match_query
      )
    )
  end

  defp apply_prefilter(query, match_query, %DateTime{} = from, nil) do
    where(
      query,
      [l],
      fragment(
        "? IN (SELECT logs_fts.rowid FROM logs_fts JOIN logs AS fts_logs ON fts_logs.id = logs_fts.rowid WHERE logs_fts MATCH ? AND fts_logs.inserted_at >= ?)",
        l.id,
        ^match_query,
        ^from
      )
    )
  end

  defp apply_prefilter(query, match_query, nil, %DateTime{} = to) do
    where(
      query,
      [l],
      fragment(
        "? IN (SELECT logs_fts.rowid FROM logs_fts JOIN logs AS fts_logs ON fts_logs.id = logs_fts.rowid WHERE logs_fts MATCH ? AND fts_logs.inserted_at <= ?)",
        l.id,
        ^match_query,
        ^to
      )
    )
  end

  defp apply_prefilter(query, match_query, %DateTime{} = from, %DateTime{} = to) do
    where(
      query,
      [l],
      fragment(
        "? IN (SELECT logs_fts.rowid FROM logs_fts JOIN logs AS fts_logs ON fts_logs.id = logs_fts.rowid WHERE logs_fts MATCH ? AND fts_logs.inserted_at >= ? AND fts_logs.inserted_at <= ?)",
        l.id,
        ^match_query,
        ^from,
        ^to
      )
    )
  end

  defp candidate_count(match_query, from, to) do
    {time_sql, time_params} = candidate_time_filter(from, to)

    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*)
        FROM (
          SELECT logs_fts.rowid
          FROM logs_fts
          #{candidate_logs_join(from, to)}
          WHERE logs_fts MATCH ?#{time_sql}
          LIMIT ?
        )
        """,
        [match_query | time_params] ++ [@candidate_cap + 1],
        timeout: 5_000
      )

    count
  end

  defp candidate_logs_join(nil, nil), do: ""

  defp candidate_logs_join(_from, _to) do
    "JOIN logs AS fts_logs ON fts_logs.id = logs_fts.rowid"
  end

  defp candidate_time_filter(nil, nil), do: {"", []}

  defp candidate_time_filter(%DateTime{} = from, nil) do
    {" AND fts_logs.inserted_at >= ?", [DateTime.to_iso8601(from)]}
  end

  defp candidate_time_filter(nil, %DateTime{} = to) do
    {" AND fts_logs.inserted_at <= ?", [DateTime.to_iso8601(to)]}
  end

  defp candidate_time_filter(%DateTime{} = from, %DateTime{} = to) do
    {" AND fts_logs.inserted_at >= ? AND fts_logs.inserted_at <= ?",
     [DateTime.to_iso8601(from), DateTime.to_iso8601(to)]}
  end

  defp match_query(tokens) do
    expressions =
      tokens
      |> Enum.flat_map(&candidate_expression/1)
      |> Enum.uniq()

    case expressions do
      [] -> :error
      expressions -> {:ok, Enum.map_join(expressions, " AND ", &parenthesize/1)}
    end
  end

  defp candidate_expression({:term, term}), do: list_expression([term])
  defp candidate_expression({:phrase, phrase}), do: list_expression([phrase])

  defp candidate_expression({:metadata, key, :eq, value}) do
    list_expression(safe_runs(key) ++ safe_runs(value))
  end

  defp candidate_expression({:metadata, key, op, _value})
       when op in [:gt, :gte, :lt, :lte] do
    list_expression(safe_runs(key))
  end

  defp candidate_expression({:regex, pattern}) do
    case regex_expression(pattern) do
      {:ok, expression} -> [expression]
      :error -> []
    end
  end

  defp candidate_expression(_token), do: []

  defp list_expression(values) do
    trigrams = values |> Enum.flat_map(&trigrams/1) |> Enum.uniq()

    case trigrams do
      [] -> []
      trigrams -> [Enum.map_join(trigrams, " AND ", &quote_token/1)]
    end
  end

  defp safe_runs(value) do
    ~r/[A-Za-z0-9_-]+/
    |> Regex.scan(value)
    |> List.flatten()
    |> Enum.filter(&(String.length(&1) >= 3))
  end

  defp regex_expression(pattern) do
    with {:ok, branches} <- split_regex_branches(String.graphemes(pattern)),
         branch_expressions <- Enum.map(branches, &regex_branch_expression/1),
         true <- branch_expressions != [] and Enum.all?(branch_expressions, &is_binary/1) do
      {:ok, Enum.map_join(branch_expressions, " OR ", &parenthesize/1)}
    else
      _reason -> :error
    end
  end

  defp split_regex_branches(graphemes) do
    do_split_regex_branches(graphemes, [], [], false)
  end

  defp do_split_regex_branches([], current, branches, false) do
    {:ok, Enum.reverse([Enum.reverse(current) | branches])}
  end

  defp do_split_regex_branches([], _current, _branches, true), do: :error

  defp do_split_regex_branches(["\\", escaped | rest], current, branches, in_class?) do
    do_split_regex_branches(rest, [escaped, "\\" | current], branches, in_class?)
  end

  defp do_split_regex_branches(["\\"], _current, _branches, _in_class?), do: :error

  defp do_split_regex_branches(["[" | rest], current, branches, false) do
    do_split_regex_branches(rest, ["[" | current], branches, true)
  end

  defp do_split_regex_branches(["]" | rest], current, branches, true) do
    do_split_regex_branches(rest, ["]" | current], branches, false)
  end

  defp do_split_regex_branches(["|" | rest], current, branches, false) do
    do_split_regex_branches(rest, [], [Enum.reverse(current) | branches], false)
  end

  defp do_split_regex_branches([paren | _rest], _current, _branches, false)
       when paren in ["(", ")"],
       do: :error

  defp do_split_regex_branches([char | rest], current, branches, in_class?) do
    do_split_regex_branches(rest, [char | current], branches, in_class?)
  end

  defp regex_branch_expression(graphemes) do
    with {:ok, atoms} <- regex_atoms(graphemes, []),
         runs <- mandatory_regex_runs(atoms),
         [expression] <- list_expression(runs) do
      expression
    else
      _reason -> nil
    end
  end

  defp regex_atoms([], atoms), do: {:ok, Enum.reverse(atoms)}

  defp regex_atoms([char | rest], atoms) when char in ["^", "$"] do
    regex_atoms(rest, atoms)
  end

  defp regex_atoms(["\\", escaped | rest], atoms) when escaped in ~w(b B A z Z G) do
    regex_atoms(rest, atoms)
  end

  defp regex_atoms(["\\", escaped | rest], atoms)
       when escaped in ~w(d D s S w W h H v V R X K p P n r t f a e) do
    add_regex_atom(rest, atoms, :separator)
  end

  defp regex_atoms(["\\", escaped | _rest], _atoms)
       when escaped in ~w(x u c o Q E 0 1 2 3 4 5 6 7 8 9),
       do: :error

  defp regex_atoms(["\\", escaped | rest], atoms) do
    atom = if safe_ascii_char?(escaped), do: {:literal, escaped}, else: :separator
    add_regex_atom(rest, atoms, atom)
  end

  defp regex_atoms(["\\"], _atoms), do: :error

  defp regex_atoms(["[" | rest], atoms) do
    with {:ok, remaining} <- consume_character_class(rest) do
      add_regex_atom(remaining, atoms, :separator)
    end
  end

  defp regex_atoms([char | rest], atoms) when char in ["."] do
    add_regex_atom(rest, atoms, :separator)
  end

  defp regex_atoms([char | _rest], _atoms) when char in ["*", "+", "?", "{", "}"] do
    # A valid regex cannot begin an atom with a quantifier. Declining here also
    # keeps future PCRE syntax extensions from becoming unsafe prefilters.
    :error
  end

  defp regex_atoms([char | rest], atoms) do
    atom = if safe_ascii_char?(char), do: {:literal, char}, else: :separator
    add_regex_atom(rest, atoms, atom)
  end

  defp add_regex_atom(rest, atoms, atom) do
    with {:ok, quantifier, remaining} <- take_quantifier(rest) do
      regex_atoms(remaining, [regex_unit(atom, quantifier) | atoms])
    end
  end

  defp take_quantifier(["*" | rest]), do: {:ok, {:variable, 0}, strip_lazy(rest)}
  defp take_quantifier(["?" | rest]), do: {:ok, {:variable, 0}, strip_lazy(rest)}
  defp take_quantifier(["+" | rest]), do: {:ok, {:variable, 1}, strip_lazy(rest)}

  defp take_quantifier(["{" | rest]) do
    {quantifier, remaining} = Enum.split_while(rest, &(&1 != "}"))

    case remaining do
      ["}" | tail] ->
        case parse_quantifier(Enum.join(quantifier)) do
          {:ok, parsed} -> {:ok, parsed, strip_lazy(tail)}
          :error -> :error
        end

      [] ->
        :error
    end
  end

  defp take_quantifier(rest), do: {:ok, :one, rest}

  defp parse_quantifier(value) do
    cond do
      Regex.match?(~r/^\d+$/, value) ->
        {:ok, {:exact, String.to_integer(value)}}

      match = Regex.run(~r/^(\d+),(\d*)$/, value) ->
        [_, minimum, maximum] = match
        minimum = String.to_integer(minimum)

        if maximum != "" and String.to_integer(maximum) == minimum do
          {:ok, {:exact, minimum}}
        else
          {:ok, {:variable, minimum}}
        end

      true ->
        :error
    end
  end

  defp strip_lazy(["?" | rest]), do: rest
  defp strip_lazy(rest), do: rest

  defp regex_unit({:literal, literal}, :one), do: {:literal, literal}

  defp regex_unit({:literal, literal}, {:exact, repetitions})
       when repetitions > 0 and repetitions <= @max_exact_regex_expansion do
    {:literal, String.duplicate(literal, repetitions)}
  end

  defp regex_unit({:literal, literal}, {kind, minimum})
       when kind in [:exact, :variable] and minimum >= 3 do
    {:standalone, String.duplicate(literal, 3)}
  end

  defp regex_unit(_atom, _quantifier), do: :separator

  defp consume_character_class(graphemes), do: do_consume_character_class(graphemes)

  defp do_consume_character_class(["\\", _escaped | rest]),
    do: do_consume_character_class(rest)

  defp do_consume_character_class(["]" | rest]), do: {:ok, rest}
  defp do_consume_character_class([_char | rest]), do: do_consume_character_class(rest)
  defp do_consume_character_class([]), do: :error

  defp mandatory_regex_runs(atoms) do
    {runs, current} =
      Enum.reduce(atoms, {[], ""}, fn
        {:literal, literal}, {runs, current} ->
          {runs, current <> literal}

        {:standalone, literal}, {runs, ""} ->
          {[literal | runs], ""}

        {:standalone, literal}, {runs, current} ->
          {[literal, current | runs], ""}

        :separator, {runs, ""} ->
          {runs, ""}

        :separator, {runs, current} ->
          {[current | runs], ""}
      end)

    [current | runs]
    |> Enum.reject(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.filter(&(String.length(&1) >= 3))
  end

  defp safe_ascii_char?(<<char::utf8>>) do
    char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?_, ?-]
  end

  defp safe_ascii_char?(_char), do: false

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

  defp parenthesize(expression), do: "(#{expression})"
end
