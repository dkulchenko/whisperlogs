defmodule WhisperLogs.SupplyChainTest do
  use ExUnit.Case, async: true

  test "all workflow actions and Docker base images are immutable references" do
    workflow_uses =
      [".github/workflows/docker-release.yml", ".github/workflows/burrito-release.yml"]
      |> Enum.flat_map(fn path ->
        Regex.scan(~r/uses:\s*([^\s#]+)/, File.read!(path), capture: :all_but_first)
      end)
      |> List.flatten()

    assert workflow_uses != []
    assert Enum.all?(workflow_uses, &Regex.match?(~r/@[0-9a-f]{40}$/, &1))

    dockerfile = File.read!("Dockerfile")

    images =
      Regex.scan(~r/^ARG\s+(?:BUILDER|RUNNER)_IMAGE="([^"]+)"$/m, dockerfile,
        capture: :all_but_first
      )
      |> List.flatten()

    assert images != []
    assert Enum.all?(images, &Regex.match?(~r/@sha256:[0-9a-f]{64}$/, &1))
  end

  test "font assets are local and carry source and license files" do
    css = File.read!("assets/css/app.css")
    root_layout = File.read!("lib/whisperlogs_web/components/layouts/root.html.heex")

    refute css =~ "fonts.googleapis.com"
    refute root_layout =~ "fonts.gstatic.com"
    assert css =~ ~s|url("/fonts/InterVariable.woff2")|
    assert css =~ ~s|url("/fonts/SourceCodeVF-Upright.woff2")|

    for file <- [
          "InterVariable.woff2",
          "SourceCodeVF-Upright.woff2",
          "INTER-LICENSE.txt",
          "SOURCE-CODE-PRO-LICENSE.md",
          "SOURCES.md"
        ] do
      assert File.regular?(Path.join("priv/static/fonts", file))
    end
  end

  test "the checked-in SQLean library matches the shared manifest" do
    extension_without_suffix = WhisperLogs.SQLean.verified_extension_path!()
    assert File.regular?(extension_without_suffix <> shared_library_suffix())

    script = File.read!("bin/download_sqlean.sh")
    assert script =~ "manifest.tsv"
    assert script =~ "sha256sum --check --status"
  end

  test "SQLean downloader rejects incomplete and path-altering manifests before download" do
    with_tmp_dir(fn root ->
      manifest = Path.join(root, "manifest.tsv")
      destination = Path.join(root, "destination")

      valid_row = fn platform, archive, library ->
        "#{platform} #{archive} #{String.duplicate("0", 64)} #{library} #{String.duplicate("1", 64)}"
      end

      incomplete = [
        valid_row.("linux-x64", "sqlean-linux-x64.zip", "regexp.so"),
        valid_row.("linux-arm64", "sqlean-linux-arm64.zip", "regexp.so"),
        valid_row.("macos-x64", "sqlean-macos-x64.zip", "regexp.dylib"),
        valid_row.("macos-arm64", "sqlean-macos-arm64.zip", "regexp.dylib")
      ]

      File.write!(manifest, Enum.join(incomplete, "\n"))
      assert {output, status} = run_sqlean_downloader(destination, manifest, root)
      assert status != 0
      assert output =~ "missing SQLean platform win-x64"
      refute File.exists?(destination)

      path_altering =
        List.replace_at(
          incomplete,
          0,
          valid_row.("linux-x64", "../sqlean-linux-x64.zip", "regexp.so")
        )

      File.write!(manifest, Enum.join(path_altering, "\n"))
      assert {output, status} = run_sqlean_downloader(destination, manifest, root)
      assert status != 0
      assert output =~ "unexpected archive for linux-x64"
      refute File.exists?(destination)
    end)
  end

  test "SQLean checksum failure cannot partially replace an existing installation" do
    with_tmp_dir(fn root ->
      archives = Path.join(root, "archives")
      destination = Path.join(root, "destination")
      manifest = Path.join(root, "manifest.tsv")
      File.mkdir_p!(archives)
      File.mkdir_p!(destination)
      File.write!(Path.join(destination, "marker"), "original")

      entries = [
        {"linux-x64", "sqlean-linux-x64.zip", "regexp.so"},
        {"linux-arm64", "sqlean-linux-arm64.zip", "regexp.so"},
        {"macos-x64", "sqlean-macos-x64.zip", "regexp.dylib"},
        {"macos-arm64", "sqlean-macos-arm64.zip", "regexp.dylib"},
        {"win-x64", "sqlean-win-x64.zip", "regexp.dll"}
      ]

      rows =
        Enum.map(entries, fn {platform, archive, library} ->
          source_dir = Path.join(root, "source-#{platform}")
          File.mkdir_p!(source_dir)
          library_path = Path.join(source_dir, library)
          File.write!(library_path, "verified-#{platform}")
          {_, 0} = System.cmd("zip", ["-q", "-j", Path.join(archives, archive), library_path])

          archive_hash = sha256_file(Path.join(archives, archive))
          library_hash = sha256_file(library_path)
          "#{platform} #{archive} #{archive_hash} #{library} #{library_hash}"
        end)

      bad_rows =
        List.update_at(
          rows,
          -1,
          &String.replace_suffix(&1, String.slice(&1, -64, 64), String.duplicate("0", 64))
        )

      File.write!(manifest, Enum.join(bad_rows, "\n"))

      assert {_output, status} = run_sqlean_downloader(destination, manifest, archives)
      assert status != 0
      assert File.read!(Path.join(destination, "marker")) == "original"
      refute File.exists?(Path.join(destination, "linux-x64"))
    end)
  end

  defp shared_library_suffix do
    case :os.type() do
      {:unix, :darwin} -> ".dylib"
      {:unix, :linux} -> ".so"
      {:win32, _} -> ".dll"
    end
  end

  defp run_sqlean_downloader(destination, manifest, base_url_path) do
    System.cmd("bash", ["bin/download_sqlean.sh"],
      env: [
        {"SQLEAN_DEST_DIR", destination},
        {"SQLEAN_MANIFEST", manifest},
        {"SQLEAN_BASE_URL", "file://#{base_url_path}"}
      ],
      stderr_to_stdout: true
    )
  end

  defp sha256_file(path) do
    :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  end

  defp with_tmp_dir(fun) do
    root =
      Path.join(System.tmp_dir!(), "whisperlogs-sqlean-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    try do
      fun.(root)
    after
      File.rm_rf!(root)
    end
  end
end
