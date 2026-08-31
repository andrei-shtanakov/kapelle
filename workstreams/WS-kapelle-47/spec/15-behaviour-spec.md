---
spec_stage: behaviour-spec
status: draft
owner_role: product
traces_to:
  - requirements
upstream_hashes:
  requirements: "6dd700fad3a635c8cf973cbd9dbe0469cd505609"
---

# Behaviour spec: Проверяемая целостность golden-фикстур

## Наблюдаемый контракт

Проверка рассматривает каждый каталог первого уровня под
`test/support/fixtures/golden/` как отдельный сценарий. Успех означает, что
сценарии существуют, у каждого есть корректный обычный файл `PROVENANCE`, а
множество checksum-записей взаимно-однозначно соответствует множеству обычных
payload-файлов и каждый записанный SHA-256 совпадает с фактическими байтами.

Любая невозможность доказать это состояние является неуспехом. Проверка ничего
не исправляет, не обращается к сети и не запускает producer.

## Общие правила примеров

- Корень, каталоги сценариев и их содержимое в отрицательных примерах создаются
  во временном каталоге; committed golden-набор не портится ради теста.
- `PROVENANCE` содержит допустимые служебные строки генератора и одну строку
  `sha256 ./<path>: <64 hex>` на каждый payload, если в сценарии не
  сказано иное.
- «Обычный файл» исключает каталог, symlink и иные специальные объекты.
- Диагностика сравнивается по стабильным полям: сценарий, относительный путь и
  класс нарушения. Порядок нескольких нарушений детерминирован.
- Один некорректный сценарий делает общий результат неуспешным, но безопасно
  обнаруживаемые нарушения других сценариев также могут быть перечислены.

## Feature: Discovery и положительный результат

#### BEH-01: Проверка неизменённого committed набора

**Given** под golden root находятся committed-сценарии `happy`, `needs_human`,
`resume` и `invalid_artifact` с текущими payload и `PROVENANCE`  
**When** запускается штатная проверка  
**Then** все четыре сценария обнаруживаются с диска  
**And** проверка завершается успешно без изменения файлов.

`traces: [FR-01, FR-04, FR-05, FR-07, FR-08]`
- **checked_by**: `status: planned` `kind: integration` `owner: qa` `target: test/golden/provenance_integrity_test.exs`

#### BEH-02: Новый сценарий попадает под контракт автоматически

**Given** под golden root добавлен каталог `future_case` с корректным manifest и
payload  
**And** имя `future_case` не упомянуто в коде проверки  
**When** запускается проверка  
**Then** `future_case` проверяется и участвует в общем результате.

`traces: [FR-01]`
- **checked_by**: `status: planned` `kind: integration` `owner: qa` `target: test/golden/provenance_integrity_test.exs`

#### BEH-03: Пустой golden root не является успехом

**Given** golden root существует, но не содержит каталогов сценариев  
**When** запускается проверка  
**Then** результат неуспешен  
**And** диагностика содержит golden root и класс `no_scenarios`.

`traces: [FR-01, FR-06]`
- **checked_by**: `status: planned` `kind: integration` `owner: qa` `target: test/golden/provenance_integrity_test.exs`

## Feature: Manifest разбирается fail-closed

#### BEH-04: Manifest обязателен и должен быть обычным читаемым файлом

**Scenario Outline:** недопустимый объект на месте manifest

**Given** существует сценарий `<scenario>`  
**And** его `PROVENANCE` имеет состояние `<state>`  
**When** запускается проверка  
**Then** результат неуспешен  
**And** диагностика содержит `<scenario>`, `PROVENANCE` и класс `<violation>`.

| state | violation |
|---|---|
| отсутствует | `manifest_missing` |
| пустой файл | `manifest_invalid` |
| каталог | `manifest_not_regular` |
| symlink | `manifest_not_regular` |
| обычный файл без права чтения | `manifest_unreadable` |

`traces: [FR-02, FR-06]`
- **checked_by**: `status: planned` `kind: integration` `owner: qa` `target: test/golden/provenance_integrity_test.exs`

#### BEH-05: Формат checksum-записи строгий

**Scenario Outline:** malformed checksum не игнорируется

**Given** manifest содержит checksum-подобную строку `<line>`  
**When** запускается проверка  
**Then** результат неуспешен  
**And** диагностика содержит сценарий, строку manifest и класс
`malformed_checksum`.

| case | line |
|---|---|
| неизвестный алгоритм | `md5 ./payload: 00000000000000000000000000000000` |
| отсутствующий путь | `sha256 : aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa` |
| отсутствующий разделитель | `sha256 ./payload aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa` |
| короткий digest | `sha256 ./payload: abc123` |
| не-hex digest | `sha256 ./payload: zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz` |

**And** допустимые служебные строки `scenario`, `producer`, `generated`,
`generator`, `generator argv`, `generator sha256` и `normalizer` не считаются
payload checksum и сами по себе не создают нарушение.

`traces: [FR-02, FR-06]`
- **checked_by**: `status: planned` `kind: integration` `owner: qa` `target: test/golden/provenance_integrity_test.exs`

## Feature: Пути остаются внутри сценария

#### BEH-06: Небезопасный или зарезервированный путь отклоняется до чтения

**Scenario Outline:** manifest не может расширить доверительную границу

**Given** checksum-запись использует путь `<path>`  
**When** запускается проверка  
**Then** путь не читается и не хешируется  
**And** результат неуспешен с классом `unsafe_path` для `<path>`.

| path |
|---|
| `/absolute` |
| `../outside` |
| `./dir/../../outside` |
| `./PROVENANCE` |
| пустой путь |

`traces: [FR-03, FR-06, NFR-01]`
- **checked_by**: `status: planned` `kind: integration` `owner: qa` `target: test/golden/provenance_integrity_test.exs`

#### BEH-07: Неканонические алиасы не обходят уникальность

**Given** manifest обозначает payload лексически неканоническим путём, например
`./workspace/./evidence.json`  
**When** запускается проверка  
**Then** результат неуспешен с классом `unsafe_path`  
**And** такой алиас не считается отдельным payload и не позволяет обойти
проверку дубликатов канонического пути.

`traces: [FR-03, FR-04, FR-06]`
- **checked_by**: `status: planned` `kind: integration` `owner: qa` `target: test/golden/provenance_integrity_test.exs`

#### BEH-08: Symlink не является payload

**Scenario Outline:** symlink fail-closed

**Given** внутри сценария находится symlink `<link>` на `<target>`  
**When** запускается проверка  
**Then** symlink не прослеживается и целевой файл через него не читается  
**And** результат неуспешен с именем сценария, путём `<link>` и классом
`non_regular_payload`.

| link | target |
|---|---|
| `./inside-link` | обычный файл внутри сценария |
| `./outside-link` | файл вне сценария |

`traces: [FR-03, FR-06, NFR-01]`
- **checked_by**: `status: planned` `kind: integration` `owner: qa` `target: test/golden/provenance_integrity_test.exs`

## Feature: Полнота и уникальность покрытия

#### BEH-09: Payload без checksum обнаруживается

**Given** в сценарий добавлен обычный файл `./workspace/unlisted.yaml`  
**And** в manifest нет записи для него  
**When** запускается проверка  
**Then** результат неуспешен с классом `unlisted_payload` и путём
`./workspace/unlisted.yaml`.

`traces: [FR-04, FR-06]`
- **checked_by**: `status: planned` `kind: integration` `owner: qa` `target: test/golden/provenance_integrity_test.exs`

#### BEH-10: Checksum без payload обнаруживается

**Given** manifest объявляет `./workspace/missing.yaml`  
**And** такого обычного файла нет  
**When** запускается проверка  
**Then** результат неуспешен с классом `missing_payload` и объявленным путём.

`traces: [FR-04, FR-06]`
- **checked_by**: `status: planned` `kind: integration` `owner: qa` `target: test/golden/provenance_integrity_test.exs`

#### BEH-11: Повторная checksum-запись запрещена

**Given** один канонический payload-путь записан в manifest дважды  
**And** digest в записях одинаковы либо различаются  
**When** запускается проверка  
**Then** результат неуспешен с классом `duplicate_checksum` и этим путём.

`traces: [FR-04, FR-06]`
- **checked_by**: `status: planned` `kind: integration` `owner: qa` `target: test/golden/provenance_integrity_test.exs`

#### BEH-12: Вложенные обычные файлы входят в покрытие

**Given** payload находится глубже одного уровня, например
`./workspace/nested/evidence.json`  
**When** его checksum присутствует и совпадает  
**Then** проверка принимает файл  
**But When** запись удалена из manifest  
**Then** тот же файл сообщается как `unlisted_payload`.

`traces: [FR-04]`
- **checked_by**: `status: planned` `kind: integration` `owner: qa` `target: test/golden/provenance_integrity_test.exs`

## Feature: Проверяется точное байтовое содержимое

#### BEH-13: Тихая побайтовая правка обнаруживается

**Given** manifest соответствует исходному payload  
**When** в payload добавлен, удалён или заменён хотя бы один байт без изменения
manifest  
**Then** результат неуспешен с классом `checksum_mismatch`  
**And** диагностика называет сценарий и относительный путь изменённого файла.

`traces: [FR-05, FR-06]`
- **checked_by**: `status: planned` `kind: integration` `owner: qa` `target: test/golden/provenance_integrity_test.exs`

#### BEH-14: Семантическая эквивалентность не заменяет равенство байтов

**Given** JSON, YAML или JSONL payload семантически эквивалентен исходному  
**When** изменены только пробелы, порядок допустимого форматирования, кодировка
или переводы строк  
**And** manifest не обновлён  
**Then** результат неуспешен как `checksum_mismatch`  
**And** проверка не нормализует содержимое перед хешированием.

`traces: [FR-05]`
- **checked_by**: `status: planned` `kind: integration` `owner: qa` `target: test/golden/provenance_integrity_test.exs`

## Feature: Интеграция, диагностика и отсутствие побочных эффектов

#### BEH-15: Несколько безопасно обнаруживаемых нарушений видны вместе

**Given** в разных сценариях есть checksum mismatch, необъявленный payload и
checksum без файла  
**When** запускается одна общая проверка  
**Then** результат неуспешен  
**And** диагностика содержит каждое нарушение с его сценарием, путём и классом  
**And** список имеет стабильный порядок независимо от порядка обхода файловой
системы и locale.

`traces: [FR-06, NFR-01]`
- **checked_by**: `status: planned` `kind: integration` `owner: qa` `target: test/golden/provenance_integrity_test.exs`

#### BEH-16: Проверка входит в штатный Mix workflow

**Given** committed golden-набор неизменён  
**When** выполняется `mix test`  
**Then** проверка целостности выполняется и проходит  
**And When** тот же тест запускается из поддерживаемого Mix workflow при ином
текущем каталоге процесса  
**Then** он находит проектный golden root и даёт тот же результат  
**And** `mix precommit` включает этот тест через обычный тестовый контур.

`traces: [FR-07, NFR-01]`
- **checked_by**: `status: planned` `kind: integration` `owner: qa` `target: test/golden/provenance_integrity_test.exs`

#### BEH-17: Проверка офлайн и только для чтения

**Given** снимок байтов и метаданных временного golden tree сохранён до запуска  
**When** положительная либо отрицательная проверка завершилась  
**Then** снимок после запуска идентичен исходному  
**And** не запускались `scripts/gen_golden.sh`, `impresario` или внешние команды
producer  
**And** не выполнялись сетевые запросы и не требовались переменные окружения.

`traces: [FR-05, FR-07, FR-08, NFR-01]`
- **checked_by**: `status: planned` `kind: integration` `owner: qa` `target: test/golden/provenance_integrity_test.exs`

#### BEH-18: Manifest штатного генератора принимается без адаптации

**Given** сценарий создан существующим `scripts/gen_golden.sh`  
**And** payload после генерации не менялся  
**When** запускается проверка  
**Then** служебные строки и checksum-записи принимаются в исходном формате  
**And** проверка проходит без переписывания manifest.

`traces: [FR-02, FR-08]`
- **checked_by**: `status: planned` `kind: integration` `owner: qa` `target: test/golden/provenance_integrity_test.exs`

## Feature: Явная граница гарантии

#### BEH-19: Согласованная правка не объявляется обнаруживаемой

**Given** payload изменён и его checksum в committed `PROVENANCE` согласованно
заменён корректным новым digest  
**When** запускается проверка  
**Then** проверка может завершиться успешно  
**And** этот результат означает только внутреннюю согласованность набора  
**And** доверие к самой правке остаётся ответственностью Git diff и review.

`traces: [NFR-01]`
- **checked_by**: `status: planned` `kind: integration` `owner: qa` `target: test/golden/provenance_integrity_test.exs`

## Матрица трассировки

| Требование | Поведенческие сценарии |
|---|---|
| REQ-001 | BS-001—BS-003 |
| REQ-002 | BS-004, BS-005, BS-018 |
| REQ-003 | BS-006—BS-008 |
| REQ-004 | BS-001, BS-007, BS-009—BS-012 |
| REQ-005 | BS-001, BS-013, BS-014, BS-017 |
| REQ-006 | BS-003—BS-011, BS-013, BS-015 |
| REQ-007 | BS-001, BS-016, BS-017 |
| REQ-008 | BS-001, BS-017, BS-018 |
| NFR-001 | BS-015—BS-017 |
| NFR-002 | BS-006, BS-008, BS-019 |

## Exit criteria behaviour-spec

- Каждый Must-критерий requirements представлен хотя бы одним наблюдаемым
  положительным или отрицательным примером.
- Негативная матрица различает требуемые классы отказа и не требует чтения за
  пределами сценария.
- Примеры задают внешний контракт проверки, не фиксируя имя будущего модуля,
  форму внутренних структур или конкретную реализацию обхода файлов.
- Граница гарантии про согласованную правку явно проверяема на уровне ожиданий и
  не превращает checksum manifest в заявленную подпись.
