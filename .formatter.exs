[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: [
    "*.{heex,ex,exs}",
    "{config,lib,test}/**/*.{heex,ex,exs}",
    # scripts/ содержит исполняемые артефакты приёмки: они вне elixirc_paths
    # и вне credo, так что формат — единственный штатный гейт, который их
    # вообще видит.
    "scripts/**/*.exs",
    "priv/*/seeds.exs"
  ]
]
