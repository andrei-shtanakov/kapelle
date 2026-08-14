import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :kapelle, Kapelle.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "kapelle_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :kapelle, KapelleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "6SvPOuC0UxIqOtZJsoETXNYKIPy9Z2f7w09awvEFXgjwsCauOkwzX/dbY89p8tvq",
  server: false

# Run Oban inline assertions in tests, no background processing
config :kapelle, Oban, testing: :manual

# The Ecto SQL sandbox wraps every test in a transaction; without this,
# Kapelle.Product.Store's ambient-transaction guard would refuse every
# write in the whole suite. This is the explicit, documented, test-only
# carve-out (owner's decision, 2026-08-14) — not a general bypass.
config :kapelle, sandbox?: true

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
