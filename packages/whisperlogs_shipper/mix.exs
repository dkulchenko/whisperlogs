defmodule WhisperLogs.Shipper.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/dkulchenko/whisperlogs"

  def project do
    [
      app: :whisperlogs_shipper,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Log shipper client for WhisperLogs",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      mod: {WhisperLogs.Shipper.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.2"},
      # Dev/test
      {:bypass, "~> 2.1", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end
end
