defmodule KapelleWeb.PageController do
  use KapelleWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
