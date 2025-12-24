defmodule WhisperLogs.Shipper.Tasks do
  @moduledoc """
  Task spawning wrapper with test-friendly behavior.

  In test mode (when `:inline_tasks` is true), tasks run synchronously.
  In dev/prod, tasks spawn via Task.Supervisor for true async execution.

  ## Examples

      # Fire-and-forget task (most common)
      WhisperLogs.Shipper.Tasks.start_child(fn ->
        send_http_request()
      end)

  ## Test Mode

  Set `inline_tasks: true` in config to run tasks synchronously:

      config :whisperlogs_shipper,
        inline_tasks: true
  """

  @doc """
  Spawns a fire-and-forget background task.

  In both test and production modes, returns `{:ok, pid}` to match the
  Task.Supervisor.start_child API. In test mode, the pid will be `self()`.
  """
  def start_child(fun) when is_function(fun, 0) do
    if inline?() do
      fun.()
      {:ok, self()}
    else
      Task.Supervisor.start_child(WhisperLogs.Shipper.TaskSupervisor, fun)
    end
  end

  defp inline? do
    Application.get_env(:whisperlogs_shipper, :inline_tasks, false)
  end
end
