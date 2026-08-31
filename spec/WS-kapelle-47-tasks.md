---
traces_to:
- design
spec_stage: tasks
status: approved
version: 2
generated_by: fleet-agent
generated_at: '2026-08-31T19:23:35'
source_prompt_version: ''
validation: warn
approved_by: andrei-shtanakov
approved_at: '2026-08-31T17:32:40Z'
---

## Milestone 1: Golden-фикстуры: PROVENANCE не проверяется ничем — тихая правка эталона необнаружима (kapelle#47)

Сгенерировано task_bridge из behaviour-spec бандла WS-kapelle-47, затем ужато
владельцем конвейера: задачи сгруппированы по Feature-секциям behaviour-spec
(1:1 «задача на сценарий» давала 19 задач с церемониальными накладными;
решение владельца 2026-08-31 — группировка). Каждая задача несёт полный
перечень покрываемых BEH-сценариев. Draft: исполнение только после
человеческого approve.

### TASK-001: Каркас проверки — discovery сценариев и fail-closed разбор PROVENANCE
P1 | ✅ DONE   Est: 1d

Модуль проверки целостности golden-набора + позитивный прогон на committed
фикстурах. Discovery каталогов первого уровня под golden root по файловой
системе (без allowlist имён), строгая грамматика checksum-записей
(`sha256 ./<path>: <64 hex>`), служебные строки генератора не читаются как
payload-записи; отсутствующий/нечитаемый/пустой manifest — падение, не skip.
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-01 (—BEH-05:
Feature «Discovery и положительный результат» + «Manifest разбирается
fail-closed»)

**Checklist:**
- [x] тест обходит каталоги под `test/support/fixtures/golden/`, находит все четыре committed-сценария и добавленный во временном каталоге новый (BEH-01, BEH-02)
- [x] пустой golden root — неуспех с указанием root, не вакуумный успех (BEH-03)
- [x] отсутствующий / нечитаемый / не-обычный / пустой `PROVENANCE` — отдельная причина отказа (BEH-04)
- [x] malformed-таблица BEH-05 (неизвестный алгоритм, нет пути, нет разделителя, короткий и не-hex digest) — все случаи красные с классом `malformed_checksum`
- [x] неизменённый committed набор проходит: `mix test` зелёный на новом тесте (BEH-01)

**Traces to:** [FR-01, FR-02, FR-04, FR-05, FR-06, FR-07, FR-08]

### TASK-002: Безопасность путей и взаимно-однозначное покрытие payload
P1 | ✅ DONE   Est: 1d

Checksum-путь — только канонический относительный путь внутри сценария;
множество объявленных путей строго равно множеству payload-файлов.
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-06 (—BEH-12:
Feature «Пути остаются внутри сценария» + «Полнота и уникальность покрытия»)
**Depends on:** [TASK-001]

**Checklist:**
- [x] `/absolute`, `../outside`, `./dir/../../outside`, `./PROVENANCE` — отклоняются до чтения содержимого с классом `unsafe_path` (BEH-06)
- [x] неканонический алиас (`./workspace/./x`) не даёт вторую запись того же payload (BEH-07)
- [x] symlink внутри и наружу сценария не хешируется и отклоняется (BEH-08)
- [x] необъявленный payload / отсутствующий payload / дубликат записи — три различимых класса (BEH-09—BEH-11)
- [x] вложенные файлы (`workspace/…` и глубже) входят в покрытие — тест на глубину ≥2 (BEH-12)

**Traces to:** [FR-03, FR-04, FR-06, NFR-01]

### TASK-003: Байтовая сверка SHA-256 и различимая диагностика
P1 | ✅ DONE   Est: 0.5d

SHA-256 по фактическим байтам без какой-либо нормализации; диагностика
называет сценарий, путь и класс; несколько независимых нарушений видны за
один прогон.
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-13 (—BEH-15:
Feature «Проверяется точное байтовое содержимое» + диагностика)
**Depends on:** [TASK-002]

**Checklist:**
- [x] правка одного байта payload при неизменном manifest — стабильный `checksum_mismatch` (BEH-13); красный воспроизведён и руками на временной копии (приёмка kapelle#47)
- [x] семантически эквивалентный, но байтово иной JSON — тоже mismatch (BEH-14)
- [x] два независимых нарушения в разных сценариях перечислены оба, порядок детерминирован (BEH-15)

**Traces to:** [FR-05, FR-06, NFR-01]

### TASK-004: Интеграция в Mix workflow, read-only гарантия и граница контракта
P2 | TODO   Est: 0.5d

Проверка живёт в штатном `mix test` (и тем самым в `mix precommit`), офлайн,
ничего не чинит; manifest штатного генератора принимается без адаптации;
граница «согласованная правка payload+manifest не обнаруживается» явно
зафиксирована.
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-16 (—BEH-19:
Feature «Интеграция, диагностика и отсутствие побочных эффектов» + «Явная
граница гарантии»)
**Depends on:** [TASK-003]

**Checklist:**
- [ ] тест бежит обычным `mix test` без env-переменных, сети и producer-checkout (BEH-16, BEH-17)
- [ ] после отрицательного прогона рабочее дерево побайтно не изменено (BEH-17)
- [ ] свежесгенерированный `scripts/gen_golden.sh` manifest проходит без ручного преобразования (BEH-18)
- [ ] согласованная правка payload+digest проходит проверку — граница задокументирована в тесте как ожидание, не как дыра (BEH-19)
- [ ] полный сьют kapelle зелёный; `mix precommit` включает новую проверку

**Traces to:** [FR-02, FR-05, FR-07, FR-08, NFR-01]
