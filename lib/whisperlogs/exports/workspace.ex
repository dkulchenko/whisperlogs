defmodule WhisperLogs.Exports.Workspace do
  @moduledoc "Creates and cleans private, application-owned export workspaces."

  @name ~r/^job-[1-9][0-9]*-[0-9a-f]{32}$/

  def root, do: Path.join(System.tmp_dir!(), "whisperlogs_exports")

  def create!(job_id) do
    ensure_safe_directory!(root(), 0o700)
    name = "job-#{job_id}-#{Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}"
    path = Path.join(root(), name)
    :ok = File.mkdir(path)
    :ok = File.chmod(path, 0o700)
    path
  end

  def create_archive!(workspace, filename) do
    unless safe_workspace?(workspace), do: raise(ArgumentError, "invalid export workspace")
    path = Path.join(workspace, filename)
    {:ok, file} = File.open(path, [:write, :binary, :exclusive])
    :ok = File.chmod(path, 0o600)
    {file, path}
  end

  def cleanup(workspace) do
    if safe_workspace?(workspace), do: File.rm_rf(workspace), else: {:error, :invalid_workspace}
  end

  def cleanup_abandoned(timeout_seconds) do
    ensure_safe_directory!(root(), 0o700)
    cutoff = System.os_time(:second) - timeout_seconds

    root()
    |> File.ls!()
    |> Enum.take(1_000)
    |> Enum.each(fn name ->
      path = Path.join(root(), name)

      case File.lstat(path, time: :posix) do
        {:ok, %{type: :directory, mtime: mtime}} when mtime < cutoff ->
          if Regex.match?(@name, name), do: File.rm_rf(path)

        _ ->
          :ok
      end
    end)
  end

  def ensure_local_destination!(path) do
    ensure_safe_directory!(path, 0o700)
    path
  end

  defp ensure_safe_directory!(path, mode) do
    expanded = Path.expand(path)
    assert_existing_components_not_symlinks!(expanded)
    :ok = File.mkdir_p(expanded)
    assert_existing_components_not_symlinks!(expanded)
    :ok = File.chmod(expanded, mode)
  end

  defp assert_existing_components_not_symlinks!(path) do
    path
    |> Path.split()
    |> Enum.reduce("", fn component, current ->
      next =
        if current in ["", "/"],
          do: Path.join("/", component),
          else: Path.join(current, component)

      case File.lstat(next) do
        {:ok, %{type: :symlink}} ->
          raise ArgumentError, "symlinked export path component"

        {:ok, %{type: type}} when type != :directory ->
          raise ArgumentError, "non-directory export path component"

        _ ->
          :ok
      end

      next
    end)
  end

  defp safe_workspace?(path) do
    expanded = Path.expand(path)
    Path.dirname(expanded) == Path.expand(root()) and Regex.match?(@name, Path.basename(expanded))
  end
end
