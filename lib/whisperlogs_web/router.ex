defmodule WhisperLogsWeb.Router do
  use WhisperLogsWeb, :router

  import WhisperLogsWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {WhisperLogsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Root redirect is handled by the authenticated live_session

  # API routes for log ingestion
  scope "/api/v1", WhisperLogsWeb do
    pipe_through [:api, WhisperLogsWeb.Plugs.ApiAuth]

    post "/logs", LogController, :ingest
  end

  # OAuth discovery, public-client registration, token exchange, and the MCP resource
  # are API-style routes: clients cannot have a browser session during discovery or token use.
  scope "/", WhisperLogsWeb do
    pipe_through :api

    get "/.well-known/oauth-protected-resource", OAuthMetadataController, :protected_resource
    get "/.well-known/oauth-protected-resource/mcp", OAuthMetadataController, :protected_resource
    get "/.well-known/oauth-authorization-server", OAuthMetadataController, :authorization_server
    post "/oauth/register", OAuthRegistrationController, :create
    post "/oauth/token", OAuthTokenController, :create

    post "/mcp", McpController, :handle
    get "/mcp", McpController, :method_not_allowed
    put "/mcp", McpController, :method_not_allowed
    patch "/mcp", McpController, :method_not_allowed
    delete "/mcp", McpController, :method_not_allowed
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:whisperlogs, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: WhisperLogsWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", WhisperLogsWeb do
    pipe_through [:browser, :require_authenticated_user]

    # Consent is a controller route in the authenticated browser pipeline because it
    # requires the existing session and current_scope assigns.
    get "/oauth/authorize", OAuthAuthorizationController, :new
    post "/oauth/authorize", OAuthAuthorizationController, :create

    live_session :require_authenticated_user,
      on_mount: [{WhisperLogsWeb.UserAuth, :require_authenticated}] do
      live "/", LogsLive
      live "/sources", SourcesLive
      live "/metrics", MetricsLive
      live "/alerts", AlertsLive
      live "/exports", ExportsLive
      live "/notification-channels", NotificationChannelsLive
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", WhisperLogsWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{WhisperLogsWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
