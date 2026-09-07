# Живой прогон против реального провайдера (BEH-28)

Инструкция для владельца, у которого есть только клон этого репозитория и
ключ провайдера — воспроизвести живой прогон DT-09 (BEH-26, BEH-27), ни разу
не спрашивая автора. Пишется после того, как DT-09 состоялся, поэтому
описывает состоявшийся прогон, а не намерение.

Проверка группы, к которой относится этот файл (`docs/live-provider-run.md`,
`kind: manual`), — человеческая: сверьте глазами, что ниже названы все четыре
факта, которых требует BEH-28. Автоматический чекер существования файла
запрещён прямо design-документом, потому что даёт зелёный на пустом файле.

## 1. Требуемая переменная окружения

`ANTHROPIC_API_KEY` — реальный ключ Anthropic. Он читается в
`config/runtime.exs` и попадает в `Application.get_env(:langchain, :anthropic_key)`.
Без него `test/kapelle/product/live_run_smoke_test.exs` отказывает во всех
своих примерах прямо в `setup_all`, до единого сетевого вызова (BEH-26).

## 2. Команда запуска

```
ANTHROPIC_API_KEY=sk-ant-... mix test --include live_product_run test/kapelle/product/live_run_smoke_test.exs
```

Файл помечен `@moduletag :live_product_run` и по умолчанию исключён
(`test/test_helper.exs`), поэтому обычный `mix test` его не трогает — нужен
именно флаг `--include live_product_run`.

## 3. Форма адреса агента

Живой агент адресуется строкой `model:<provider>@<model>`, например
`model:anthropic@claude-haiku-4-5`. По умолчанию тест использует именно этот
адрес; переопределить модель или бюджет итераций можно переменными
окружения, не редактируя файл теста:

- `KAPELLE_LIVE_RUN_AGENT` — адрес вида `model:anthropic@<model>` (умолчание —
  самая дешёвая модель каталога, `model:anthropic@claude-haiku-4-5`);
- `KAPELLE_LIVE_RUN_MAX_ITERATIONS` — бюджет итераций цикла (умолчание `1`).

## 4. Где смотреть результат

Прохождение теста из шага 2 уже само по себе — evidence для BEH-27/AC-22:
тест сам вызывает `RunVerdict.for_loop/1` и `Report.format/1` и утверждает
(`assert`), что `cost.tokens` измерено и положительно, а отчёт называет
живого агента. `loop_id` при успешном прогоне нигде отдельно не печатается
и не логируется — искать его в успешном выводе `mix test` не нужно и
бесполезно; если же один из этих `assert` упадёт, ExUnit напечатает
провалившееся значение `report` целиком, а первая строка `Report.format/1`
всегда — `loop:    <loop_id>` (см. `lib/mix/tasks/kapelle.product.report.ex`),
так что при падении `loop_id` в выводе всё-таки виден — хотя строки цикла и
вызовов агента к этому моменту уже откачены sandbox'ом (см. ниже) и
дальнейшего смотрения через `mix kapelle.product.report` не переживают.

Чтобы увидеть тот же отчёт глазами, а не только пройденный тест,
`mix kapelle.product.report <loop_id>` нужно направить не на прогон
теста, а на свой собственный прогон через `Kapelle.Product.Loop.start/2` —
и вот почему это обязательно: тест использует `Kapelle.DataCase`, чья SQL
sandbox откатывает транзакцию сразу по выходу из теста, поэтому строки
цикла и вызовов агента, записанные во время `mix test`, физически не
переживают процесс `mix test` — команда `mix kapelle.product.report`,
запущенная после него отдельным процессом, ничего не найдёт (усугубляется
тем, что она по умолчанию поднимается в `MIX_ENV=dev`, а не `test`, — две
разные базы). Рабочий путь — ключ нужен и здесь, `iex -S mix` без него
даст `:anthropic_key = nil` (`config/runtime.exs`) и вызов провалится
отказом авторизации:

```
ANTHROPIC_API_KEY=sk-ant-... iex -S mix
```

и внутри той же сессии вызвать `Kapelle.Product.Loop.start/2` с тем же
идея-фикстуром, что использует тест
(`test/support/fixtures/golden/happy/workspace/idea.yaml`), и всеми пятью
опциями, которые требует `Loop.start/2` (`lib/kapelle/product/loop.ex`) —
`loop_id`, `proposal_id`, `exchange_log_id`, `max_iterations` и `agent`
обязательны, без умолчаний:

```elixir
Kapelle.Product.Loop.start(
  File.read!("test/support/fixtures/golden/happy/workspace/idea.yaml"),
  loop_id: "LOOP-1",
  proposal_id: "PP-1",
  exchange_log_id: "XL-1",
  max_iterations: 1,
  agent: "model:anthropic@claude-haiku-4-5"
)
```

Очередь `:product` в dev реально запущена
(`config/config.exs`), поэтому Oban доработает джобы сам — дождитесь, пока
`Kapelle.Product.Loops.get!(loop_id).status` станет терминальным, и уже из
любого терминала (в том же `MIX_ENV`) вызовите:

```
mix kapelle.product.report <loop_id>
```

Отчёт называет адрес живого агента (`agent:   model:anthropic@claude-haiku-4-5`);
токены он печатает только если вызов реально измерил usage — если провайдер
ничего не сообщил (например, ретрай), строка `tokens:` читается
`not instrumented`, а не число. Измеренное число токенов — это и есть факт,
который нужно предъявить как evidence AC-22; `not instrumented` фактом не
является, и в этом случае прогон стоит повторить.
