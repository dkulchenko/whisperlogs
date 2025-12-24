defmodule WhisperLogs.Shipper.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      if enabled?() do
        [
          {Task.Supervisor, name: WhisperLogs.Shipper.TaskSupervisor},
          WhisperLogs.Shipper
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: WhisperLogs.Shipper.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp enabled? do
    Application.get_env(:whisperlogs_shipper, :enabled, false)
  end
end
