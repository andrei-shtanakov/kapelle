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

## Текущее состояние (2026-08-17, master `2e147f0`)

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

## Правила ведения

- Выполненный пункт → `[x]` + хеш коммита/номер PR.
- Прямые коммиты в `master` запрещены: ветка → PR → ревью Copilot → мержит человек.
- Чужие репо не правим: нужна правка у соседа — handoff в
  `../prograph-vault/authored/notes/`.

## Активные задачи

- [ ] **codex-review PR-B: caller-workflow гейта** @id:codex-review-caller — @epic:eco.codex-review-rollout
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
- [ ] **human_waiver parity case** @id:human-waiver-parity — carry-forward S3: @epic:airun.kapelle-m3
  golden-сценарий «критический assumption снят waiver'ом → цикл проходит» +
  parity-тест; сейчас поле покрыто только юнитами `next_stage_test.exs`.
- [ ] **PROVENANCE self-integrity** @id:golden-provenance-self-integrity — @epic:airun.kapelle-m3
  carry-forward S3 (N4–N6): тест, сверяющий golden-фикстуры с sha256 из их
  PROVENANCE — тихая правка golden-набора сегодня необнаружима.
- [ ] **Product loop в LiveView + two-axis verdict** @id:s4-plus-tail-decision @epic:airun.kapelle-m3
  — §8 «S4+», §1 (включая cost-visibility per run): решить судьбу при
  закрытии M3 — доделывать или явно вынести за срез (сейчас честный
  `harness=observability_gap`).
- [ ] **Сверка статусов `spec/tasks.md`** @id:tasks-md-reconciliation — @epic:airun.kapelle-m3
  сверить канонические статусы с фактически влитыми PR; по правилу
  project.yaml статусы reconcile'ятся вручную после финального PR волны.
- [ ] **Реальные LLM/provider-адаптеры** @id:real-provider-adapters — вместо @epic:airun.kapelle-m3
  fixture-backed deterministic агентов (Research/Creator/Evaluator через
  behaviour/port); отдельная веха после M3 (решение 3 дизайна, PR #14).

## Ждём от других проектов

- (пусто — impresario#14 закрыт 2026-08-16)
