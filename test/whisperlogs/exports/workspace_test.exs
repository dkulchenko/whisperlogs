defmodule WhisperLogs.Exports.WorkspaceTest do
  use ExUnit.Case, async: false

  alias WhisperLogs.Exports.Workspace

  test "creates private workspaces and archives and removes only the validated workspace" do
    workspace = Workspace.create!(123)
    on_exit(fn -> Workspace.cleanup(workspace) end)

    assert %{type: :directory, mode: workspace_mode} = File.stat!(workspace)
    assert Bitwise.band(workspace_mode, 0o077) == 0

    {file, archive} = Workspace.create_archive!(workspace, "archive.jsonl.gz")
    :ok = IO.binwrite(file, "archive")
    :ok = File.close(file)

    assert %{type: :regular, mode: archive_mode} = File.stat!(archive)
    assert Bitwise.band(archive_mode, 0o077) == 0
    assert {:error, :invalid_workspace} = Workspace.cleanup(Path.dirname(workspace))
    assert File.exists?(workspace)
    assert {:ok, _entries} = Workspace.cleanup(workspace)
    refute File.exists?(workspace)
  end

  test "rejects a symlink in a local destination path" do
    root =
      Path.join(System.tmp_dir!(), "whisperlogs-path-#{System.unique_integer([:positive])}")

    real = Path.join(root, "real")
    link = Path.join(root, "link")
    File.mkdir_p!(real)
    :ok = File.ln_s(real, link)
    on_exit(fn -> File.rm_rf(root) end)

    assert_raise ArgumentError, ~r/symlinked export path component/, fn ->
      Workspace.ensure_local_destination!(Path.join(link, "child"))
    end
  end
end
