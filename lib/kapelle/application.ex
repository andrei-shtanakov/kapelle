defmodule Kapelle.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      KapelleWeb.Telemetry,
      Kapelle.Repo,
      {Oban, Application.fetch_env!(:kapelle, Oban)},
      {DNSCluster, query: Application.get_env(:kapelle, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Kapelle.PubSub},
      # Start a worker by calling: Kapelle.Worker.start_link(arg)
      # {Kapelle.Worker, arg},
      # Start to serve requests, typically the last entry
      KapelleWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Kapelle.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    KapelleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
