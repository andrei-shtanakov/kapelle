# Приёмка S4 — вердикт (2026-08-17)

Статус: приёмка проведена 2026-08-17 на `master@da7739d` (TODO
`@id:s4-acceptance`). Сверка исполненного (PR #18–#25, S4-волна влита
2026-08-16) с чартером —
`docs/superpowers/specs/2026-08-14-product-context-design.md` §8 («S4+ —
through the contour», exit gates) и §5 (durable boundary, шесть
fault-точек) — плюс carry-forwards из S3-плана (human_waiver parity,
PROVENANCE self-integrity N4–N6).

Верификация на момент приёмки: `mix test` — **492 теста, 0 падений**
(1 исключён: `provider_smoke` — реальные адаптеры провайдеров, отдельная
веха после M3).

## Закрыто (exit gates §8-S4)

1. **`needs_human` hold с inspectable state** — TASK-105 (PR #18/#19).
   Фикстурный агент детерминированно ведёт цикл в `needs_human` через
   обычный worker-контур; терминальный статус и причинные артефакты
   читаются через канонический `View`; очередь пуста; повторный
   reconcile — `in_sync`; доменные наблюдения сходятся с golden-оракулом
   `golden/needs_human` (`test/kapelle/product/resume_test.exs`,
   «the resume case's domain observations agree with the golden
   needs-human oracle»).

2. **`needs_human` не продвигается без валидного активного человеческого
   свидетельства** — TASK-106 (PR #20 интейк + PR #21). Чартер ставил
   fail-closed как exit-критерий «пока продюсерский контракт не
   существует»; контракт `loop-resume-decision/v1` доставлен
   (impresario#14 закрыт), завендорен в PR #20 на пине `8082e53`,
   резюме активировано. Анти-микс инвариант держится: все **восемь**
   контрактов на одном producer_commit (проверено по PIN-файлам).
   Refusal-матрица fail-closed — 13 кейсов в
   `test/kapelle/product/resume_test.exs` («refusal matrix»): нет
   решения; schema-invalid; чужой subject; не-расширяющий бюджет;
   superseded; self/циклический `supersedes`; dangling supersedes;
   дубликат decision_id; больше одного активного; unknown loop_id —
   каждый оставляет hold на месте и очередь пустой.

3. **Резюме, будучи активированным, идемпотентно** — TASK-106.
   Повторное предъявление потреблённого решения — no-op (в т.ч.
   position-independent после дальнейшего прогресса цикла); второй
   reconcile — `in_sync`. Consume-переход атомарен в нашем сторе (одна
   DB-транзакция), job байт-идентичен обычному контуру
   (`StageShell.stage_job_changeset/4`).

4. **Все шесть fault-границ зелёные + per-write идемпотентность** —
   TASK-107 (PR #24/#25).
   `test/kapelle/product/fault_injection_matrix_test.exs`: точки 1–6 §5
   инжектируются через обычный контур; happy-точки 1–4 сходятся к happy
   golden по каноническому хешу; corruption-точки 5–6 fail-closed без
   попытки ремонта (ни одной новой ревизии); redelivery/re-run нигде не
   дублирует артефакт, событие или job. Evaluate/apply tear получил
   решённое, оттестированное поведение (кейс C1): heal как у
   research/concept + chain-правило `View`
   `:missing_orchestration_entry` как fail-closed backstop для
   отклонённого heal (I1 закрыт — `9879c7c`, добивка покрытия по ревью
   PR #25 — `8ef2db7`).

5. **Полная parity-матрица зелёная** — happy
   (`parity_happy_test.exs`) / needs-human hold (парити-часть п.1;
   чартер требовал «asserts the hold, not the resume, until the
   contract lands» — контракт приземлился, и утверждение штатно
   перевёрнуто в resume) / invalid-artifact (PR #23: golden
   `invalid_artifact`, normalizer v2,
   `parity_invalid_artifact_test.exs`) / crash
   (`parity_crash_test.exs`). Сверх чартера: полный resume-golden
   parity (PR #22) — golden `resume` сгенерирован продюсером на том же
   пине, продюсерский `decisions/lrd-001.yaml` потреблён как есть,
   drain-after-resume до `ready` с oracle-равными хешами
   (`parity_resume_test.exs`).

6. **Single-flight per loop** — механизм §5: ключ уникальности
   `(loop_id, iteration, stage, input_hash)` через Oban `unique:
   [fields: [:worker, :args]]`
   (`lib/kapelle/product/workers/stage_shell.ex`,
   `enqueue_stage/4`). Утверждён fault-точками 2 и 3 (re-enqueue ровно
   недостающего job; redelivery без второго job) и reconciler-тестами.
   Зафиксированная в moduledoc оговорка: insert-дедуп Oban ограничен
   окном `period: 60` — реплей за пределами окна покрывается
   idempotent-skip-шагом самого shell, а не дедупом вставки; это
   честная записанная граница механизма, exit gate ей не нарушен.

## Переносится (не закрыто в S4)

1. **human_waiver parity case** (carry-forward S3-плана). Семантика поля
   покрыта юнитами (`next_stage_test.exs`: waived assumption не
   блокирует), но golden-сценария «критический assumption снят
   человеческим waiver'ом → цикл проходит» нет ни в
   `test/support/fixtures/golden/` (там 4 сценария: happy,
   needs_human, invalid_artifact, resume), ни в parity-тестах.

2. **PROVENANCE self-integrity (N4–N6)** (carry-forward S3-плана).
   PROVENANCE-файлы всех четырёх golden-сценариев полны (producer-пин,
   argv и sha256 генераторов, версия нормализатора, sha256 каждого
   файла, единый пин `8082e53`), но **ни один тест не сверяет golden-
   фикстуры с записанными хешами** — тихая правка golden-набора сегодня
   необнаружима.

3. **Product loop в LiveView** (§8 «S4+»). Не начато: `run_live` /
   `runs_live` — поверхности оркестратора из M1, product-контекст в
   LiveView не отражён. LiveView-инвариант чартера при этом не нарушен
   (читать нечего — значит, ничего и не влияет на исполнение).

4. **Two-axis verdict reporting** (§8 «S4+», §1) и видимость
   **cost/interventions per run** (§1, §9.3 exit). Кода отчётности нет
   (grep по `cost` в продуктовом и web-слое пуст). Для закрывающего
   M3-вердикта это честный `harness=observability_gap` — по чартеру
   «useful result, not a rounding error» — либо явное решение владельца
   вынести за срез M3.

## Итог

Все шесть exit-gate-пунктов §8-S4 (hold, fail-closed evidence, идемпотентное
резюме, шесть fault-границ, полная parity-матрица, single-flight)
**закрыты с тестовым свидетельством на пине `8082e53`**. Открытыми
остаются четыре пункта выше; из них 1–2 — техдолг golden-набора, 3–4 —
объявленный «S4+»-хвост чартера, судьба которого решается при закрытии
M3 двухосевым вердиктом product/harness.
