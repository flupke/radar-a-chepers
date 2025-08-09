defmodule RadarWeb.PageController do
  use RadarWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
