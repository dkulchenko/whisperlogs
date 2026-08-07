defmodule WhisperLogs.MixProject do
  use Mix.Project

  def project do
    [
      app: :whisperlogs,
      version: "0.4.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {WhisperLogs.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, "test.adapters": :test]
    ]
  end

  defp releases do
    steps =
      if System.get_env("WHISPERLOGS_SKIP_BURRITO") in ["1", "true"] do
        [:assemble]
      else
        [:assemble, &Burrito.wrap/1]
      end

    [
      whisperlogs: [
        steps: steps,
        burrito: [
          targets: [
            linux: [os: :linux, cpu: :x86_64],
            linux_arm: [os: :linux, cpu: :aarch64],
            macos: [os: :darwin, cpu: :x86_64],
            macos_arm: [os: :darwin, cpu: :aarch64],
            windows: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:bcrypt_elixir, "~> 3.0"},
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.14"},
      # Postgrex 0.22.4 is under the seven-day dependency quarantine.
      {:postgrex, "~> 0.22.3 and < 0.22.4"},
      {:ecto_sqlite3, "~> 0.24.1"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.7", only: :dev},
      {:phoenix_live_view, "~> 1.2.8"},
      {:lazy_html, "~> 0.1.12", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5.1", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.27"},
      {:req, "~> 0.7.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.4.5"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.12.4"},
      {:tz, "~> 0.28.2"},
      {:date_time_parser, "~> 1.2"},
      {:burrito, "~> 1.6"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "test.adapters": [&test_adapters/1],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind whisperlogs", "esbuild whisperlogs"],
      "assets.deploy": [
        "compile",
        "tailwind whisperlogs --minify",
        "esbuild whisperlogs --minify",
        "phx.digest"
      ],
      release: ["assets.deploy", "release", "phx.digest.clean --all"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "test.adapters"
      ]
    ]
  end

  defp test_adapters(args) do
    run_adapter_tests!("postgres", args)
    run_adapter_tests!("sqlite", args)
  end

  defp run_adapter_tests!(adapter, args) do
    Mix.shell().info([:bright, "\nRunning #{adapter} test suite\n"])

    env =
      [{"MIX_ENV", "test"}] ++
        if adapter == "sqlite" do
          [{"WHISPERLOGS_TEST_ADAPTER", "sqlite"}]
        else
          [{"WHISPERLOGS_TEST_ADAPTER", "postgres"}]
        end

    case System.cmd("mix", ["test" | args], env: env, into: IO.stream(:stdio, :line)) do
      {_output, 0} ->
        :ok

      {_output, status} ->
        Mix.raise("#{adapter} test suite failed with status #{status}")
    end
  end
end
