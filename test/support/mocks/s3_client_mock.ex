defmodule WhisperLogs.Exports.S3ClientMock do
  @moduledoc """
  Mock S3 client for testing exports without real S3 calls.

  Uses the test process mailbox to track calls and allow assertions.
  The mock agent is started automatically in test_helper.exs.

  ## Usage

  Configure the application to use this mock in your test setup:

      setup do
        Application.put_env(:whisperlogs, :s3_client, WhisperLogs.Exports.S3ClientMock)
        on_exit(fn -> Application.delete_env(:whisperlogs, :s3_client) end)
        :ok
      end

  Then in your test:

      test "uploads to S3" do
        # Run the code that calls S3
        Exporter.run_export(job)

        # Assert on the mock calls
        assert_received {:s3_put_object, config, key, _body, _opts}
        assert config.s3_bucket == "test-bucket"
        assert String.ends_with?(key, ".jsonl.gz")
      end

  To simulate errors:

      setup do
        S3ClientMock.set_response(:error)
        on_exit(fn -> S3ClientMock.set_response(:ok) end)
      end
  """

  use Agent

  @doc """
  Starts the mock agent for tracking state.
  Called automatically by test_helper.exs.
  """
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{response: :ok, calls: []} end, name: __MODULE__)
  end

  @doc """
  Sets the response mode for subsequent calls.
  """
  def set_response(mode) when mode in [:ok, :error] do
    Agent.update(__MODULE__, &Map.put(&1, :response, mode))
  end

  @doc """
  Gets all recorded calls.
  """
  def get_calls do
    Agent.get(__MODULE__, & &1.calls)
  end

  @doc """
  Clears recorded calls.
  """
  def clear_calls do
    Agent.update(__MODULE__, &Map.put(&1, :calls, []))
  end

  @doc """
  Mock implementation of put_object/4.

  Sends a message to the calling process for assertion and returns
  based on the configured response mode.
  """
  def put_object(config, key, body, opts \\ []) do
    call = {:s3_put_object, config, key, body, opts}

    # Send to calling process for assertions
    send(self(), call)

    # Record in agent
    Agent.update(__MODULE__, fn state ->
      %{state | calls: [call | state.calls]}
    end)

    case Agent.get(__MODULE__, & &1.response) do
      :ok -> :ok
      :error -> {:error, "Simulated S3 error"}
    end
  end

  @doc """
  Mock implementation of test_connection/1.
  """
  def test_connection(config) do
    call = {:s3_test_connection, config}
    send(self(), call)

    Agent.update(__MODULE__, fn state ->
      %{state | calls: [call | state.calls]}
    end)

    case Agent.get(__MODULE__, & &1.response) do
      :ok -> :ok
      :error -> {:error, "Connection failed"}
    end
  end
end
