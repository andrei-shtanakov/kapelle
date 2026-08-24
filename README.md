# Kapelle

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## Codex review kit (vendored)

`scripts/review/` + `.github/codex/review-schema.json` — вендор-копия
codex-review-кита из steward (независимое ревью дифа другой моделью), пин —
`scripts/review/PIN`. Copy-integrity проверяет джоба `review-kit-integrity`
в CI (чекер исполняется извлечённым из base), дрейф от продюсера ловит
вахта `review-kit-drift.yml`. `review-prompt.md` — данные этого репо (вне
integrity), generated-файлы объявляются в `.gitattributes`
(`linguist-generated`). Локальный прогон: `sh scripts/review/local.sh`.
Ре-вендор — рецепт в комментарии PIN; смена состава кита — двухшаговая
дисциплина из шапки `checksum.sh`.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
