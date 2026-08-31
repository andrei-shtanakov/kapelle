---
spec_stage: tasks
status: draft
version: 1
generated_by: fleet-agent
generated_at: 2026-08-31T19:23:35
source_prompt_version: ""
validation: ""
approved_by: ""
---

## Milestone 1: Golden-фикстуры: PROVENANCE не проверяется ничем — тихая правка эталона необнаружима (kapelle#47)

Сгенерировано task_bridge из behaviour-spec бандла WS-kapelle-47 (шаг 3 плана развития конвейера). Draft: исполнение только после человеческого approve.

### TASK-001: Проверка неизменённого committed набора
P2 | TODO   Est: 0.5d

Реализовать поведение BEH-01 (Проверка неизменённого committed набора).
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-01

**Checklist:**
- [ ] реализовать BEH-01: Проверка неизменённого committed набора
- [ ] проверка сценария BEH-01: test/golden/provenance_integrity_test.exs (kind: integration) зелёный

**Traces to:** [FR-01, FR-04, FR-05, FR-07, FR-08]

### TASK-002: Новый сценарий попадает под контракт автоматически
P2 | TODO   Est: 0.5d

Реализовать поведение BEH-02 (Новый сценарий попадает под контракт автоматически).
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-02

**Checklist:**
- [ ] реализовать BEH-02: Новый сценарий попадает под контракт автоматически
- [ ] проверка сценария BEH-02: test/golden/provenance_integrity_test.exs (kind: integration) зелёный

**Traces to:** [FR-01]

### TASK-003: Пустой golden root не является успехом
P2 | TODO   Est: 0.5d

Реализовать поведение BEH-03 (Пустой golden root не является успехом).
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-03

**Checklist:**
- [ ] реализовать BEH-03: Пустой golden root не является успехом
- [ ] проверка сценария BEH-03: test/golden/provenance_integrity_test.exs (kind: integration) зелёный

**Traces to:** [FR-01, FR-06]

### TASK-004: Manifest обязателен и должен быть обычным читаемым файлом
P2 | TODO   Est: 0.5d

Реализовать поведение BEH-04 (Manifest обязателен и должен быть обычным читаемым файлом).
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-04

**Checklist:**
- [ ] реализовать BEH-04: Manifest обязателен и должен быть обычным читаемым файлом
- [ ] проверка сценария BEH-04: test/golden/provenance_integrity_test.exs (kind: integration) зелёный

**Traces to:** [FR-02, FR-06]

### TASK-005: Формат checksum-записи строгий
P2 | TODO   Est: 0.5d

Реализовать поведение BEH-05 (Формат checksum-записи строгий).
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-05

**Checklist:**
- [ ] реализовать BEH-05: Формат checksum-записи строгий
- [ ] проверка сценария BEH-05: test/golden/provenance_integrity_test.exs (kind: integration) зелёный

**Traces to:** [FR-02, FR-06]

### TASK-006: Небезопасный или зарезервированный путь отклоняется до чтения
P2 | TODO   Est: 0.5d

Реализовать поведение BEH-06 (Небезопасный или зарезервированный путь отклоняется до чтения).
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-06

**Checklist:**
- [ ] реализовать BEH-06: Небезопасный или зарезервированный путь отклоняется до чтения
- [ ] проверка сценария BEH-06: test/golden/provenance_integrity_test.exs (kind: integration) зелёный

**Traces to:** [FR-03, FR-06, NFR-01]

### TASK-007: Неканонические алиасы не обходят уникальность
P2 | TODO   Est: 0.5d

Реализовать поведение BEH-07 (Неканонические алиасы не обходят уникальность).
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-07

**Checklist:**
- [ ] реализовать BEH-07: Неканонические алиасы не обходят уникальность
- [ ] проверка сценария BEH-07: test/golden/provenance_integrity_test.exs (kind: integration) зелёный

**Traces to:** [FR-03, FR-04, FR-06]

### TASK-008: Symlink не является payload
P2 | TODO   Est: 0.5d

Реализовать поведение BEH-08 (Symlink не является payload).
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-08

**Checklist:**
- [ ] реализовать BEH-08: Symlink не является payload
- [ ] проверка сценария BEH-08: test/golden/provenance_integrity_test.exs (kind: integration) зелёный

**Traces to:** [FR-03, FR-06, NFR-01]

### TASK-009: Payload без checksum обнаруживается
P2 | TODO   Est: 0.5d

Реализовать поведение BEH-09 (Payload без checksum обнаруживается).
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-09

**Checklist:**
- [ ] реализовать BEH-09: Payload без checksum обнаруживается
- [ ] проверка сценария BEH-09: test/golden/provenance_integrity_test.exs (kind: integration) зелёный

**Traces to:** [FR-04, FR-06]

### TASK-010: Checksum без payload обнаруживается
P2 | TODO   Est: 0.5d

Реализовать поведение BEH-10 (Checksum без payload обнаруживается).
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-10

**Checklist:**
- [ ] реализовать BEH-10: Checksum без payload обнаруживается
- [ ] проверка сценария BEH-10: test/golden/provenance_integrity_test.exs (kind: integration) зелёный

**Traces to:** [FR-04, FR-06]

### TASK-011: Повторная checksum-запись запрещена
P2 | TODO   Est: 0.5d

Реализовать поведение BEH-11 (Повторная checksum-запись запрещена).
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-11

**Checklist:**
- [ ] реализовать BEH-11: Повторная checksum-запись запрещена
- [ ] проверка сценария BEH-11: test/golden/provenance_integrity_test.exs (kind: integration) зелёный

**Traces to:** [FR-04, FR-06]

### TASK-012: Вложенные обычные файлы входят в покрытие
P2 | TODO   Est: 0.5d

Реализовать поведение BEH-12 (Вложенные обычные файлы входят в покрытие).
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-12

**Checklist:**
- [ ] реализовать BEH-12: Вложенные обычные файлы входят в покрытие
- [ ] проверка сценария BEH-12: test/golden/provenance_integrity_test.exs (kind: integration) зелёный

**Traces to:** [FR-04]

### TASK-013: Тихая побайтовая правка обнаруживается
P2 | TODO   Est: 0.5d

Реализовать поведение BEH-13 (Тихая побайтовая правка обнаруживается).
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-13

**Checklist:**
- [ ] реализовать BEH-13: Тихая побайтовая правка обнаруживается
- [ ] проверка сценария BEH-13: test/golden/provenance_integrity_test.exs (kind: integration) зелёный

**Traces to:** [FR-05, FR-06]

### TASK-014: Семантическая эквивалентность не заменяет равенство байтов
P2 | TODO   Est: 0.5d

Реализовать поведение BEH-14 (Семантическая эквивалентность не заменяет равенство байтов).
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-14

**Checklist:**
- [ ] реализовать BEH-14: Семантическая эквивалентность не заменяет равенство байтов
- [ ] проверка сценария BEH-14: test/golden/provenance_integrity_test.exs (kind: integration) зелёный

**Traces to:** [FR-05]

### TASK-015: Несколько безопасно обнаруживаемых нарушений видны вместе
P2 | TODO   Est: 0.5d

Реализовать поведение BEH-15 (Несколько безопасно обнаруживаемых нарушений видны вместе).
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-15

**Checklist:**
- [ ] реализовать BEH-15: Несколько безопасно обнаруживаемых нарушений видны вместе
- [ ] проверка сценария BEH-15: test/golden/provenance_integrity_test.exs (kind: integration) зелёный

**Traces to:** [FR-06, NFR-01]

### TASK-016: Проверка входит в штатный Mix workflow
P2 | TODO   Est: 0.5d

Реализовать поведение BEH-16 (Проверка входит в штатный Mix workflow).
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-16

**Checklist:**
- [ ] реализовать BEH-16: Проверка входит в штатный Mix workflow
- [ ] проверка сценария BEH-16: test/golden/provenance_integrity_test.exs (kind: integration) зелёный

**Traces to:** [FR-07, NFR-01]

### TASK-017: Проверка офлайн и только для чтения
P2 | TODO   Est: 0.5d

Реализовать поведение BEH-17 (Проверка офлайн и только для чтения).
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-17

**Checklist:**
- [ ] реализовать BEH-17: Проверка офлайн и только для чтения
- [ ] проверка сценария BEH-17: test/golden/provenance_integrity_test.exs (kind: integration) зелёный

**Traces to:** [FR-05, FR-07, FR-08, NFR-01]

### TASK-018: Manifest штатного генератора принимается без адаптации
P2 | TODO   Est: 0.5d

Реализовать поведение BEH-18 (Manifest штатного генератора принимается без адаптации).
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-18

**Checklist:**
- [ ] реализовать BEH-18: Manifest штатного генератора принимается без адаптации
- [ ] проверка сценария BEH-18: test/golden/provenance_integrity_test.exs (kind: integration) зелёный

**Traces to:** [FR-02, FR-08]

### TASK-019: Согласованная правка не объявляется обнаруживаемой
P2 | TODO   Est: 0.5d

Реализовать поведение BEH-19 (Согласованная правка не объявляется обнаруживаемой).
Source: workstreams/WS-kapelle-47/spec/15-behaviour-spec.md#BEH-19

**Checklist:**
- [ ] реализовать BEH-19: Согласованная правка не объявляется обнаруживаемой
- [ ] проверка сценария BEH-19: test/golden/provenance_integrity_test.exs (kind: integration) зелёный

**Traces to:** [NFR-01]

