# TODO — kapelle (создан 2026-08-17, при вводе во флот)

> Роль в экосистеме: Elixir/Oban-оркестратор — **полигон боевой обкатки №1**
> контура spec-runner/Maestro (m1/m2 TDD-evidence фазы) и потребитель
> вендоренных контрактов impresario (bounded context `Kapelle.Product`,
> airun-M3). Kapelle НЕ имеет runtime-зависимостей на checkout impresario —
> только пинованные вендоренные схемы (boundary guard в
> `test/kapelle/product/boundary_guard_test.exs`).
>
> SSOT операционного бэклога фаз — `spec/tasks.md` (TASK-NNN); дизайн
> product-slices S1–S4 — `docs/superpowers/plans/2026-08-14-product-s*.md`.
> Здесь — пункты уровня репо (two-plane, ADR-ECO-005).
>
> Пункты могут быть размечены тегами на строке чекбокса:
> `@owner:<principal>` / `@blocked_by:<reference>` / `@trigger:"…"` / `@id:<node-id>`
> (грамматика `[a-z0-9][a-z0-9._-]{0,63}`, URI `todo://kapelle/<id>`).
> Отсутствие тега значит «неизвестно» — значения не выдумываем.

## Текущее состояние (2026-09-06, master `91cda67`)

- ✅ **M1 vertical slice закрыт** (7/7, PR #6); m2 TDD-evidence фаза закрыта
  4/4 (PR #7–#13).
- ✅ **Product-slices S1–S3 закрыты** (PR #15/#16/#17): 7 контрактов impresario
  завендорены одним snapshot'ом с drift-вахтой; Store с immutable
  version-снапшотами; нативные workers + детерминированные fake-агенты;
  golden-parity с reference runner'ом impresario.
- ✅ **S4-волна прошла 2026-08-16**: intake `loop-resume-decision/v1`
  (PR #20, impresario#14 закрыт), human-resume как чистый consumer
  (TASK-106), fault-injection matrix (TASK-107, PR #24/#25).
- ✅ Переезд под зонтик `all_ai_orchestrators` + ввод во флот — этот PR.
- ✅ **M3 ЗАКРЫТ 2026-09-06** — приёмка
  `docs/superpowers/acceptance/2026-09-06-m3-acceptance.md`: все восемь
  критериев §1/§9.3 закрыты, четыре переноса S4 разобраны, закрывающий вердикт
  `product: pass, harness: pass` предъявлен живым прогоном двух golden-сценариев
  через штатный контур. Вне среза — `real-provider-adapters` (#50) и
  `product-loop-liveview`.

## Правила ведения

- Выполненный пункт → `[x]` + хеш коммита/номер PR.
- Прямые коммиты в `master` запрещены: ветка → PR → ревью Copilot → мержит человек.
- Чужие репо не правим: нужна правка у соседа — handoff в
  `../prograph-vault/authored/notes/`.

## Активные задачи

- [x] **codex-review PR-B: caller-workflow гейта** @id:codex-review-caller — влит #33 (`3c169b4`, 2026-08-24), приёмка одним платным прогоном (minor вне порога) — @epic:eco.codex-review-rollout
  по образцу пилота spec-runner (механика из base, потолки,
  generated-декларация, экономный триггер по драфту/лейблу) + лейбл
  `codex-review` + секрет `CODEX_REVIEW_API_KEY` (кладёт владелец в
  настройки репо) — после мержа PR-A. PR-A: кит завендорен —
  `scripts/review/` (5 POSIX-скриптов) + `.github/codex/review-schema.json`,
  PIN @ steward `9916787`; copy-integrity — джоба `review-kit-integrity` в
  ci.yml (чекер из base, на первом PR — бутстрап-notice); upstream-drift —
  вахта `review-kit-drift.yml` (не PR-гейт); `review-prompt.md` — данные
  репо, вне integrity; `.gitattributes` объявил `mix.lock`. Ре-вендор —
  рецепт в комментарии PIN; kapelle — четвёртый потребитель, проверка
  POSIX-портируемости кита на Elixir-репо.

- [x] **Финальная приёмка S4** @id:s4-acceptance — сверить исполненное
  (PR #20–#25) с чартером S4 (needs_human resume, per-write идемпотентность /
  полная fault matrix, single-flight per loop, human_waiver в parity-матрице,
  PROVENANCE self-integrity) и явно объявить, что закрыто, а что переносится.
  Вердикт: `docs/superpowers/acceptance/2026-08-17-s4-acceptance.md` — все
  шесть exit-gates §8-S4 закрыты (492 теста зелёные на `da7739d`);
  переносятся четыре пункта (см. ниже). Фактический охват сверки — PR
  #18–#25: gate «needs_human hold» (TASK-105) влит PR #18/#19, до
  постановки этого пункта.
- [x] **@id-теги на строки чекбоксов** @id:invisible-ids-on-continuation-lines
  — inbox kapelle#29 (детектор DT-TAG-ON-CONTINUATION, devtools#57):
  два тега стояли отдельными строками-продолжениями и были невидимы
  построчным парсерам; заодно подняты на строки чекбоксов остальные
  четыре `@id` этого файла — они стояли в хвостах строк-продолжений и
  были невидимы так же, просто не флагуются (детектор нарочно щадит
  упоминания в прозе). PR #30.
- [x] **mix_audit как dev-деп** @id:mix-audit-dev-dep — inbox kapelle#38, PR #42:
  архивная установка mix_audit сломана по построению (не несёт
  `yaml_elixir`), канонический канал — dev-зависимость проекта
  `{:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}` +
  шаг `mix deps.audit` в CI (ритуал R-2 hardening sweep, ADR-ECO-009).
- [x] **human_waiver parity case** @id:human-waiver-parity — @epic:airun.kapelle-m3 — PR #62
      Evidence: golden `human_waiver` на пине 8082e53 — от `happy` отличается
      ровно одним полем cd-002 (`human_waiver` вместо `answered_by`), поэтому
      исход атрибутируем waiver'у; `parity_human_waiver_test.exs` — контур
      через воркеры → ready с oracle-равными хешами плюс негативный контроль
      (тот же скрипт без waiver держится на needs_human); 505 tests, 0 failures.
      Попутно починен генератор: `mix run --no-start` + гейт формы версии —
      stdout запущенного приложения затекал в строку `normalizer:` манифеста
      PROVENANCE, то есть свидетельство зависело от машины оператора.
  carry-forward S3: golden-сценарий «критический assumption снят waiver'ом →
  цикл проходит» + parity-тест; поле было покрыто только юнитами
  `next_stage_test.exs`.
- [x] **PROVENANCE self-integrity** @id:golden-provenance-self-integrity — @epic:airun.kapelle-m3 — kapelle#47 закрыт (PR #51—#59)
      Evidence: behaviour-бандл WS-kapelle-47 (PR #51) → tasks-спека (PR #53) →
      TASK-001–004 (PR #55—#59); master a56af35 — 502 tests, 0 failures.
      Проверка живёт в mix test / mix precommit (Kapelle.Golden.ProvenanceIntegrity).
  carry-forward S3 (N4–N6): тест, сверяющий golden-фикстуры с sha256 из их
  PROVENANCE — тихая правка golden-набора сегодня необнаружима.
- [x] **S4+ tail decision расщеплён** @id:s4-plus-tail-decision @epic:airun.kapelle-m3
  — compatibility-якорь для прежнего `todo://kapelle/s4-plus-tail-decision`;
  преемники: `two-axis-verdict`, `s4-plus-cost-visibility`,
  `s4-plus-liveview`.
- [x] **Two-axis verdict и поверхность отчёта** @id:two-axis-verdict @epic:airun.kapelle-m3 — PR #64
      Evidence: `Kapelle.Product.RunVerdict` — ось product читает
      терминальный lifecycle цикла, а walk канонического view
      (`NextStage.compute/2`, тот же, с которым сверяется reference runner)
      применяется, когда терминал не записан (`status: "running"`);
      доменный провал опознаётся по двум формам `stop_reason`, остальное
      `failed` уходит в харнесс. Ось harness — по фактам исполнения
      (целостность свидетельства, discarded, осиротевшие executing,
      незаписанный терминал). Неизмеренное не печатается нулём: `tokens` =
      nil с причиной, счётчики nil при нечитаемом свидетельстве. Токенная
      запись — не дефект: `token_usage/1` (шов под реальный адаптер)
      возвращает nil, потому что провайдера не вызывали — см. пункт
      `s4-plus-cost-visibility`. Видимая
      половина §9.3 — `mix kapelle.product.report <loop_id>`. master 0cbc699 —
      521 tests, 0 failures. Ревью-контур снял три major (осиротевший
      executing читался как «джоб ещё отработает»; `failed` шёл в продуктовый
      провал даже когда его писал сам харнесс; готовый результат без записи
      статуса демотировался в :open) и два minor.
- [x] **Cost на прогон: §9.3 выполнен** @id:s4-plus-cost-visibility @epic:airun.kapelle-m3 — PR #68
  Решение владельца 2026-09-06 (записано в спеку, §1): «cost visible per
  run» в M3 = наблюдаемость фактически возникающих расходов — итерации,
  stage-джобы, попытки, ретраи, recovery/discard-состояния, ревизии
  артефактов, wall time. Всё это измеряется и печатается
  (`mix kapelle.product.report`), `interventions` доставлены в PR #64.
  Токены здесь **неприменимы, а не потеряны**: реальные адаптеры вынесены
  §9 за срез, вызова модели не происходит. `tokens = nil` — свидетельство
  (`:cost_not_applicable`, severity `:info`), не дефект, и ось harness не
  опускает; иначе отсутствие провайдера смешивалось бы с потерей
  наблюдаемости существующего расхода и M3 не закрывался бы по
  построению. Утверждение «провайдера не вызывали» выводится из адреса
  агента (`Agent.fixture?/1`), а не из отсутствия цифры: живая схема без
  инструментовки попадает в `:cost_not_instrumented`/`:gap` и краснит ось
  сама — отказ fail-closed. Токенная инструментовка — в
  `real-provider-adapters`.
- [x] **Product loop в LiveView: вынесен за M3** @id:s4-plus-liveview @epic:airun.kapelle-m3 — PR #69
  Решение владельца 2026-09-06 (записано в спеку, §8): экран продуктового
  цикла в M3 не делается и в exit среза не входит — ни в §1, ни в
  exit-гейт §8; LiveView-инвариант чартера при этом не нарушен: читать
  нечего, значит на исполнение не влияет. Сегодняшний читатель один —
  владелец и приёмочное ревью, — а `mix kapelle.product.report <loop_id>`
  для него более полная read-поверхность, чем экран: обе оси, findings,
  весь cost-блок, interventions со ссылками на артефакты.
  Причина выноса — **порядок проектирования, а не экономия работы**:
  сейчас экран закрепил бы UX вокруг fixture-only мира, а после реальных
  адаптеров появляются настоящая стоимость, отказы провайдера, фоновые
  прогоны и операторские действия — они и определяют информационную
  архитектуру. Преемник — `product-loop-liveview`.
- [x] **Сверка статусов `spec/tasks.md`** @id:tasks-md-reconciliation — @epic:airun.kapelle-m3 — PR #70
  Сверка 2026-09-06 против merge-истории репо, объём — **все три
  канонических tasks-файла** (`spec/tasks.md` 8 задач, `spec/m2-tasks.md` 7,
  `spec/WS-kapelle-47-tasks.md` 4): расхождений статусов **нет** — все 19
  задач действительно доставлены на `master`, ни один статус не менялся. Что чинилось —
  отсутствующие ссылки на подтверждение: до прохода PR/коммит нёс один
  TASK-001, теперь под каждым статусом стоит `**Delivered:**` с PR и
  merge-коммитом. Это был последний открытый пункт **работы внутри среза**
  M3 — доставлять по нему больше нечего. Два пункта эпика остаются
  открытыми намеренно, как post-M3 преемники: `real-provider-adapters`
  (вынесен §9 чартера) и `product-loop-liveview` (вынесен решением
  владельца 2026-09-06, ждёт первого). Тег `@epic:airun.kapelle-m3` они
  несут по сложившейся в файле конвенции — вопрос, заводить ли для
  post-M3 работы отдельный эпик, решается в плоскости эпиков
  (ADR-ECO-010) сразу для обоих, а не здесь.
- [x] **Приёмка M3 — закрывающий двухосевой вердикт** @id:m3-acceptance @epic:airun.kapelle-m3 — PR #71
  `docs/superpowers/acceptance/2026-09-06-m3-acceptance.md` на `master@91cda67`,
  526 тестов / 0 падений. Вердикт предъявлен, а не заявлен: два golden-сценария
  (`happy`, `human_waiver`) проведены через штатный worker-контур на изолированной
  БД, отчёт напечатан настоящей `mix kapelle.product.report` — обе оси `pass`,
  `waivers: 1 (concept-draft://CD-002)` показывает названную интервенцию.
  До PR #68 такой вердикт был недостижим по построению.
- [ ] **Реальные LLM/provider-адаптеры** @id:real-provider-adapters — вместо @epic:airun.kapelle-m3
  fixture-backed deterministic агентов (Research/Creator/Evaluator через
  behaviour/port); отдельная веха после M3 (решение 3 дизайна, PR #14).
  Несёт токенную половину §9.3 — три состояния обязаны остаться
  различимыми (решение владельца 2026-09-06): провайдер не вызывался →
  `tokens` nil / `:not_applicable`, finding `:cost_not_applicable`
  severity `:info`; usage измерен как ноль → `0`, finding нет; провайдер
  вызывался, а usage потерян → nil / `:not_instrumented`, finding
  `:cost_not_instrumented` severity `:gap`. Именно третье возвращает
  `:observability_gap` в достижимые ветки.
- [ ] **Экран продуктового цикла (LiveView)** @id:product-loop-liveview @epic:airun.kapelle-m3 @blocked_by:todo://kapelle/real-provider-adapters
  Преемник вынесенного за M3 `s4-plus-liveview` (решение владельца
  2026-09-06). Читающая половина уже есть — `View.build/1`,
  `RunVerdict.for_loop/1`, `Loops`, — так что работа здесь про
  информационную архитектуру, а не про доменную логику. Проектируется
  **после** реальных адаптеров и отдельным PR: сначала #50 стабилизирует
  данные и операторские сценарии (живая стоимость, отказы провайдера,
  фоновые прогоны), затем экран. Объединять с `real-provider-adapters`
  в один чекбокс или PR нельзя — это разные предметы и разный порядок.
  LiveView-инвариант чартера остаётся в силе: только чтение производной
  проекции, отсутствие или устаревание не влияет на исполнение.

## Ждём от других проектов

- (пусто — impresario#14 закрыт 2026-08-16)
