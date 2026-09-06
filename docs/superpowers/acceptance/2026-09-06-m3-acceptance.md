# Приёмка M3 — закрывающий двухосевой вердикт (2026-09-06)

Статус: приёмка проведена 2026-09-06 на `master@91cda67` (TODO
`@id:tasks-md-reconciliation` — последний закрытый пункт работы внутри среза).
Сверка исполненного с чартером —
`docs/superpowers/specs/2026-08-14-product-context-design.md` §1 (exit M3) и
§9.3 (критерии durability) — плюс разбор четырёх переносов приёмки S4
(`2026-08-17-s4-acceptance.md`).

Верификация на момент приёмки: `mix test` — **526 тестов, 0 падений**
(1 исключён: `provider_smoke` — реальные адаптеры провайдеров, вынесены §9 за
срез).

## Закрывающий вердикт: предъявлен, а не заявлен

Два golden-сценария проведены через штатный worker-контур на изолированной
БД, вердикт напечатан настоящей CLI-командой — той самой «видимой половиной»
§9.3:

```
drain LOOP-HAPPY: discard=0 failure=0
drain LOOP-WAIVER: discard=0 failure=0

$ mix kapelle.product.report LOOP-HAPPY
loop:    LOOP-HAPPY
product: pass — no open critical assumptions/gaps and no open requests
harness: pass
  - cost_not_applicable (info): :no_provider_call

cost:
  iterations:         2 / 2
  stage jobs:         6
  attempts:           6
  retries:            0
  discarded:          0
  cancelled:          0
  executing:          0
  orphaned:           0
  artifact revisions: 16
  wall ms:            123
  tokens:             not applicable (fixture-backed agents)

interventions:
  holds:              0
  resumes:            0
  waivers:            0

$ mix kapelle.product.report LOOP-WAIVER
loop:    LOOP-WAIVER
product: pass — no open critical assumptions/gaps and no open requests
harness: pass
  - cost_not_applicable (info): :no_provider_call

cost:
  iterations:         2 / 2
  stage jobs:         6
  attempts:           6
  retries:            0
  discarded:          0
  cancelled:          0
  executing:          0
  orphaned:           0
  artifact revisions: 16
  wall ms:            92
  tokens:             not applicable (fixture-backed agents)

interventions:
  holds:              0
  resumes:            0
  waivers:            1 (concept-draft://CD-002)
```

**`product: pass, harness: pass` — вердикт, которого этот срез не мог выдать
ещё вчера.** До PR #68 finding `cost_not_instrumented`/`:gap` выставлялся
безусловно, и `harness_axis` уходил в `:observability_gap` на **каждом**
прогоне: M3 не закрывался по построению. Сегодня отсутствие токенов —
свидетельство `:cost_not_applicable`/`:info`, а не дефект, и ось это больше не
опускает (решение владельца, §1 чартера, ruling 2026-09-06).

Два прогона выбраны намеренно: `LOOP-HAPPY` показывает чистый цикл без
человеческих вмешательств, `LOOP-WAIVER` — тот же зелёный вердикт при
**реальной интервенции**, названной, а не сосчитанной: `waivers: 1
(concept-draft://CD-002)`. Вместе они и есть «cost and interventions are
visible per run».

### Как воспроизвести

```sh
MIX_ENV=test MIX_TEST_PARTITION=acc mix ecto.create && \
MIX_ENV=test MIX_TEST_PARTITION=acc mix ecto.migrate
# скрипт: install_script! из golden-воркспейса → Loop.start/2 →
#         Oban.drain_queue(queue: :product, with_recursion: true) →
#         Mix.Task.run("kapelle.product.report", [loop_id])
MIX_ENV=test MIX_TEST_PARTITION=acc mix ecto.drop
```

Прогон одноразовый и в дерево ничего не пишет: отдельная БД по
`MIX_TEST_PARTITION`, `Sandbox.mode(:auto)`, скрипт живёт вне репозитория.
`wall ms` — единственное поле, которое от прогона к прогону меняется.

## Критерии выхода §1/§9.3

| критерий | статус | свидетельство |
|---|---|---|
| ready-case завершается без ручных правок состояния | ✅ | живой прогон выше (`LOOP-HAPPY`, drain `discard=0 failure=0`, `product: pass`); `e2e_happy_test.exs` |
| крах после каждой durable-границы резюмируется без дублей | ✅ | TASK-107, `fault_injection_matrix_test.exs` (точки 1–6 §5), `parity_crash_test.exs` — приёмка S4 п.4 |
| поздние/дублирующие результаты не перетирают терминальный вердикт | ✅ | fault-точки 2–3 и per-write идемпотентность — приёмка S4 п.4 |
| одна итерация не применяется дважды | ✅ | single-flight `(loop_id, iteration, stage, input_hash)` + idempotent-skip шага — приёмка S4 п.6 |
| невалидные артефакты останавливают прогресс fail-closed | ✅ | `parity_invalid_artifact_test.exs`, corruption-точки 5–6 без ремонта — приёмка S4 п.4–5 |
| needs-human держит инспектируемое состояние и путь резюме | ✅ | TASK-105/106, refusal-матрица 13 кейсов, идемпотентное резюме — приёмка S4 п.1–3 |
| **cost и interventions видны на прогон** | ✅ | `Kapelle.Product.RunVerdict` (PR #64) + семантика трёх состояний стоимости (PR #68) + живые блоки выше; ruling §1 |
| эталон и Kapelle сходятся на фикстурах | ✅ | пять golden-сценариев (`happy`, `needs_human`, `invalid_artifact`, `resume`, `human_waiver`) и пять parity-тестов на пине `8082e53` |

## Четыре переноса приёмки S4 — разобраны все

1. **human_waiver parity case** — **закрыт**. PR #62: golden `human_waiver`
   отличается от `happy` ровно одним полем `cd-002` (`human_waiver` вместо
   `answered_by`), поэтому исход атрибутируем waiver'у; `parity_human_waiver_test.exs`
   гоняет контур через воркеры до `ready` с oracle-равными хешами плюс
   негативный контроль (тот же скрипт без waiver держится на `needs_human`).
   Issue kapelle#46 закрыт.

2. **PROVENANCE self-integrity (N4–N6)** — **закрыт**. kapelle#47, PR #51—#59:
   `Kapelle.Golden.ProvenanceIntegrity` сверяет golden-фикстуры с sha256 из их
   PROVENANCE; проверка живёт в `mix test` / `mix precommit`, то есть тихая
   правка эталона больше не необнаружима.

3. **Product loop в LiveView** — **вынесен за M3** решением владельца
   2026-09-06 (ruling §8 + §9 «Out of scope»). Экран не входит ни в один
   exit-список, а инвариант чартера делает его отсутствие безвредным:
   читать нечего — на исполнение не влияет. Причина выноса — порядок
   проектирования: построенный сейчас экран закрепил бы информационную
   архитектуру вокруг fixture-only мира. Преемник —
   `todo://kapelle/product-loop-liveview`, `@blocked_by` реальных адаптеров.

4. **Two-axis verdict и видимость cost/interventions** — **закрыт**.
   Отчётность доставлена (PR #64), семантика стоимости приведена в порядок
   (PR #66—#68). Приёмка S4 оставляла развилку «честный
   `harness=observability_gap` либо явное решение владельца» — выбран третий,
   точный ответ: критерий §9.3 признан выполненным по существу, а токены
   объявлены **неприменимыми, а не потерянными**.

## Решения владельца 2026-09-06 (оба записаны в чартер)

**§9.3 «cost visible per run»** — наблюдаемость фактически возникающих
расходов: итерации, stage-джобы, попытки, ретраи, recovery/discard-состояния,
ревизии артефактов, wall time. Токены неприменимы, пока провайдер не
вызывается (§9 выносит реальные адаптеры за срез); считать это стоящим гэпом
значило бы смешать отсутствие провайдера с потерей наблюдаемости
существующего расхода. Три состояния стоимости обязаны остаться различимыми и
защищены тестами:

| состояние | `tokens` | причина | finding |
|---|---|---|---|
| провайдер не вызывался (адрес — `fixture:<key>`) | `nil` | `:not_applicable` | `:cost_not_applicable`, `:info` |
| вызван, потратил ноль | `0` | — | нет |
| вызван, usage потерян | `nil` | `:not_instrumented` | `:cost_not_instrumented`, `:gap` |

Направление вывода — от **адреса агента** (`Agent.fixture?/1`), а не от
отсутствия цифры: живая схема без инструментовки попадает в третье состояние и
краснит ось сама. Отказ fail-closed (находка ревью PR #68).

**LiveView** — вынесен за M3, см. перенос 3 выше.

## Границы среза и преемники

Вне M3 остаются два пункта, оба с записанными обязательствами:

- `todo://kapelle/real-provider-adapters` (kapelle#50) — несёт токенную
  половину §9.3; «Готово, когда» перечисляет все три состояния стоимости и
  требует, чтобы отображение осталось различимым;
- `todo://kapelle/product-loop-liveview` — `@blocked_by` первого.

Оба несут `@epic:airun.kapelle-m3` по сложившейся в `TODO.md` конвенции;
вопрос, заводить ли отдельный эпик для post-M3 работы, решается в плоскости
эпиков (ADR-ECO-010) сразу для обоих.

## Итог

Все восемь критериев выхода §1/§9.3 закрыты, четыре переноса приёмки S4
разобраны (два доставлены, один вынесен решением владельца, один закрыт по
существу), бухгалтерия сверена: 19 задач трёх канонических tasks-файлов
подтверждены merge-историей (PR #70).

**Закрывающий вердикт среза — `product: pass, harness: pass`**, предъявленный
живым прогоном обоих golden-сценариев через штатный контур, а не выведенный из
зелёных тестов. `harness=observability_gap` в этом срезе недостижим: гэпов
наблюдаемости в нём не осталось, а ветка ждёт реальных адаптеров, чтобы снова
стать содержательной.

**M3 закрыт.**
