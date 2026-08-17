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

- [x] **Финальная приёмка S4**: сверить исполненное (PR #20–#25) с чартером
  S4 (needs_human resume, per-write идемпотентность / полная fault matrix,
  single-flight per loop, human_waiver в parity-матрице, PROVENANCE
  self-integrity) и явно объявить, что закрыто, а что переносится.
  Вердикт: `docs/superpowers/acceptance/2026-08-17-s4-acceptance.md` — все
  шесть exit-gates §8-S4 закрыты (492 теста зелёные на `da7739d`);
  переносятся четыре пункта (см. ниже). Фактический охват сверки — PR
  #18–#25: gate «needs_human hold» (TASK-105) влит PR #18/#19, до
  постановки этого пункта. @id:s4-acceptance
- [ ] **human_waiver parity case** (carry-forward S3): golden-сценарий
  «критический assumption снят waiver'ом → цикл проходит» + parity-тест;
  сейчас поле покрыто только юнитами `next_stage_test.exs`.
  @id:human-waiver-parity
- [ ] **PROVENANCE self-integrity** (carry-forward S3, N4–N6): тест, сверяющий
  golden-фикстуры с sha256 из их PROVENANCE — тихая правка golden-набора
  сегодня необнаружима. @id:golden-provenance-self-integrity
- [ ] **Product loop в LiveView + two-axis verdict / cost-visibility**
  (§8 «S4+», §1): решить судьбу при закрытии M3 — доделывать или явно
  вынести за срез (сейчас честный `harness=observability_gap`).
  @id:s4-plus-tail-decision
- [ ] **Сверка канонических статусов `spec/tasks.md`** с фактически влитыми
  PR — по правилу project.yaml статусы reconcile'ятся вручную после
  финального PR волны. @id:tasks-md-reconciliation
- [ ] **Реальные LLM/provider-адаптеры** вместо fixture-backed deterministic
  агентов (Research/Creator/Evaluator через behaviour/port) — отдельная веха
  после M3 (решение 3 дизайна, PR #14). @id:real-provider-adapters

## Ждём от других проектов

- (пусто — impresario#14 закрыт 2026-08-16)
