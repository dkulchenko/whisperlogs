defmodule WhisperLogsWeb.Plugs.RuntimeSession do
  @moduledoc false

  @verification_options [
    store: :cookie,
    key: "_whisperlogs_key",
    signing_salt: "FVIHYGtG"
  ]

  def verification_options, do: @verification_options

  def init(opts), do: opts

  def call(conn, _opts) do
    options =
      @verification_options
      |> Keyword.merge(
        secure: Application.get_env(:whisperlogs, :secure_cookies, false),
        http_only: true,
        same_site: "Lax"
      )
      |> Plug.Session.init()

    Plug.Session.call(conn, options)
  end
end
