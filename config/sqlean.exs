fn ->
  expected_files = %{
    "linux-x64" => {"sqlean-linux-x64.zip", "regexp.so"},
    "linux-arm64" => {"sqlean-linux-arm64.zip", "regexp.so"},
    "macos-x64" => {"sqlean-macos-x64.zip", "regexp.dylib"},
    "macos-arm64" => {"sqlean-macos-arm64.zip", "regexp.dylib"},
    "win-x64" => {"sqlean-win-x64.zip", "regexp.dll"}
  }

  platform =
    case :os.type() do
      {:unix, :darwin} ->
        if String.contains?(:erlang.system_info(:system_architecture) |> List.to_string(), [
             "aarch64",
             "arm"
           ]), do: "macos-arm64", else: "macos-x64"

      {:unix, :linux} ->
        if String.contains?(:erlang.system_info(:system_architecture) |> List.to_string(), [
             "aarch64",
             "arm"
           ]), do: "linux-arm64", else: "linux-x64"

      {:win32, _} ->
        "win-x64"
    end

  root = Path.expand("../priv/sqlite_extensions", __DIR__)

  entries =
    root
    |> Path.join("manifest.tsv")
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.reduce(%{}, fn line, entries ->
      case String.split(line, ~r/\s+/, parts: 5) do
        [entry_platform, archive, archive_hash, library, library_hash] ->
          expected = Map.get(expected_files, entry_platform)

          if expected != {archive, library} or
               not Regex.match?(~r/\A[0-9a-f]{64}\z/, archive_hash) or
               not Regex.match?(~r/\A[0-9a-f]{64}\z/, library_hash) or
               Map.has_key?(entries, entry_platform) do
            raise "invalid or duplicate SQLean manifest entry for #{entry_platform}"
          end

          Map.put(entries, entry_platform, {archive, archive_hash, library, library_hash})

        _ ->
          raise "malformed SQLean manifest entry"
      end
    end)

  if MapSet.new(Map.keys(entries)) != MapSet.new(Map.keys(expected_files)) do
    raise "SQLean manifest must contain exactly the five supported platforms"
  end

  {_archive, _archive_hash, library, expected_hash} = Map.fetch!(entries, platform)
  full_path = Path.join([root, platform, library])

  case File.lstat(full_path) do
    {:ok, %{type: :regular}} -> :ok
    _ -> raise "SQLean library is missing or not regular: #{full_path}"
  end

  actual_hash = :crypto.hash(:sha256, File.read!(full_path)) |> Base.encode16(case: :lower)
  if actual_hash != expected_hash, do: raise("SQLean library checksum mismatch: #{full_path}")
  Path.rootname(full_path)
end
