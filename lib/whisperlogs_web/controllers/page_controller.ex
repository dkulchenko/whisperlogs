defmodule WhisperLogsWeb.PageController do
  use WhisperLogsWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
