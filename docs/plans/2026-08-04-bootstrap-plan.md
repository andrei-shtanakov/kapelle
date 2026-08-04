# Elixir-оркестратор: план бутстрапа нового проекта

> Дата: 2026-08-04. Статус: план, утверждённые вводные из интервью.
> **Имя проекта: `kapelle`. Репозиторий: `/Users/Andrei_Shtanakov/labs/kapelle`.**
> Вводные: **независимый продукт** (экосистема — источник паттернов, не зависимость),
> **один Phoenix-проект с контекстами**, **Oban для распределённого выполнения на старте**,
> **исполнитель — двойной, за абстракцией** (CLI-агенты + LLMChain).

## TL;DR

1. Новый проект — отдельный репозиторий **вне** `all_ai_orchestrators/`:
   `/Users/Andrei_Shtanakov/labs/kapelle/`, свой git + GitHub remote. В реестр экосистемы не входит; из неё
   берём только идеи контрактов (read-only reference).
2. Стек: Elixir + Phoenix (LiveView-дашборд), Ecto/PostgreSQL, **Oban** (очереди,
   ретраи, распределённые воркеры), **langchain `~> 0.9`** (единый интерфейс
   провайдеров: Anthropic, OpenAI, Google, xAI, Ollama и др.).
3. Пять компонентов экосистемы отображаются на **контексты одного приложения**:
   Orchestrator (≈maestro), Router (≈arbiter), Executor (≈spec-runner+спаунеры),
   Evaluator (≈atp-platform), Dashboard (≈dispatcher). Границы — behaviours +
   структуры-контракты, чтобы позже любой контекст можно было выделить в сервис.
4. Первая цель — **вертикальный срез M1**: задача → роутер выбирает модель →
   исполнитель (LLMChain с tools) → евалюатор (LLM-judge) → вердикт в LiveView.
   Только после этого наращивать DAG, CLI-агентов и кластер.
5. Главные риски: (а) Elixir LangChain — это тонкая обёртка над chat+tools, а не
   агентный фреймворк из Python-мира — часть придётся писать самим; (б) «свой
   кодировщик на LLMChain» — ловушка скоупа, реальный кодинг делегировать CLI-агентам
   через Port; (в) не тащить governance-слой экосистемы в greenfield.

---

## 1. Маппинг: экосистема → контексты Elixir-приложения

| Компонент экосистемы | Роль | В новом проекте | Что именно позаимствовать (файлы-референсы) |
|---|---|---|---|
| **maestro** (Python, DAG-оркестратор) | планирование, спаун агентов, worktrees | контекст `Orchestrator`: `Run`, `Task`, DAG-зависимости в Postgres, шаги — Oban-джобы | паттерн spawners/адаптеров; sentinel/recovery-логика (`orchestrator.py:_SPAWNING_SENTINEL`); идея `project.yaml` как декларативного DAG |
| **arbiter** (Rust, MCP policy engine) | маршрутизация задача→агент/модель | контекст `Router`: behaviour `Router.Policy`; старт с explicit-правил, потом статистика исходов | 22-мерный feature vector; 10 инвариантов fail-closed; `decision_id` в ответе + `report_outcome` для замыкания петли |
| **spec-runner** + CLI-агенты | исполнение leaf-задач | контекст `Executor`: behaviour `Executor.Adapter` с двумя реализациями — `ChainAdapter` (LLMChain+tools) и `CliAgentAdapter` (Port → Claude Code/Codex/Aider в git worktree) | контракт `--json-result` + exit-коды `0/1/2` (pass/fail/error) — воспроизвести дословно |
| **atp-platform** | оценка/бенчмарки | контекст `Evaluator`: behaviour `Evaluator.Judge` (llm-judge, code-exec, artifact-check), вердикты в БД | список 13 оценщиков как чек-лист; `happy_only`-урок: скоринг версионировать с самого начала |
| **dispatcher** | дашборд/управление | `<App>Web`: LiveView — runs, live-стрим токенов (PubSub), guarded actions (cancel/retry) | принцип «view поверх snapshot + мутации только через белый список» |
| **agents-catalog.toml** (ATP, SSOT моделей) | каталог агентов/моделей | `priv/catalog/models.toml` + контекст `Providers`: фабрика LangChain-моделей по `provider@model` | формат `atp-platform/method/agents-catalog.toml`, конвенция id `<harness>@<model>` |
| **observability-контракт** (maestro/contracts/) | трейсы/JSONL | `:telemetry` + OpenTelemetry (в langchain есть `config :langchain, :open_telemetry, enabled: true`) | W3C TraceContext-пропагация в subprocess-ы CLI-агентов (`TRACEPARENT`) |
| **proctor** Phase 3 (Docker/SSH-воркеры) | распределённые исполнители | **не сейчас**: Oban-воркеры на нескольких нодах покрывают старт; выделенные execution-ноды — этап M6 | runbook-долг proctor'а по remote-orphan cleanup — учесть заранее |

Чего сознательно **нет** на старте: steward/governance-гейтов, discovery-контура,
полирепо, вендоринга контрактов, MCP-серверов. Это налог зрелой мульти-репо
экосистемы; в одном приложении его платить не за что. Правило анти-паттернов
экосистемы (`prograph-vault/authored/rules/agent-theater-checklist.md`) действует и
тут: роли — только runtime-функции, верификация сильнее генерации.

## 2. Стек и ключевые зависимости

| Библиотека | Зачем | Комментарий/альтернатива |
|---|---|---|
| `phoenix`, `phoenix_live_view` | web-слой, дашборд, live-стриминг | SSR+WebSocket из коробки; отдельный SPA не нужен |
| `ecto_sql` + PostgreSQL | состояние runs/tasks/verdicts | SQLite (как в экосистеме) не подойдёт: Oban требует Postgres |
| `oban` | очереди `orchestrator/executor/evaluator`, ретраи, uniqueness, cron | бесплатный Oban не имеет Workflow (DAG) — зависимости шагов строим сами таблицей `task_deps`; Oban Pro — платный, на старте не нужен |
| `langchain ~> 0.9` | единый интерфейс LLM-провайдеров, tools, streaming, token-usage | ключевой аргумент против «самописного Req-клиента»: смена провайдера = смена структуры `ChatAnthropic`/`ChatOpenAI`/`ChatGoogleAI`/`ChatOllamaAI`, остальной код не меняется |
| `req` | HTTP для всего остального | уже транзитивно есть |
| `libcluster` (+ опц. `horde`) | **позже (M6)**: автосборка BEAM-кластера | для очередей не нужен — Oban распределяется через Postgres; нужен для live-стейта/Presence между нодами |
| `credo`, `dialyxir`, `mix format` | линт/типы/стиль | аналог ruff/pyrefly-дисциплины экосистемы |

Критика выбора langchain (честно): это НЕ Python LangChain. Нет готовых
агент-харнессов, RAG-конвейеров, memory-модулей — есть `LLMChain` +
`Message` + `Function`(tools) + провайдеры + callbacks. Для роутера/евалюатора
этого достаточно и даже лучше (меньше магии); для «кодировщика» — см. риск R-2.

## 3. Структура проекта (один Phoenix-проект, контексты)

```
kapelle/
├── lib/kapelle/
│   ├── orchestrator/        # Run, Task, DAG, планирование; Oban-джобы шага
│   │   ├── run.ex  task.ex  dag.ex  planner.ex
│   │   └── workers/step_worker.ex
│   ├── router/              # выбор исполнителя/модели
│   │   ├── policy.ex        # behaviour: route(task, catalog) -> {:ok, decision}
│   │   ├── rules_policy.ex  # v1: явные правила
│   │   └── decision.ex      # decision_id, features, outcome — как у arbiter
│   ├── executor/
│   │   ├── adapter.ex       # behaviour: execute(task, decision) -> json_result
│   │   ├── chain_adapter.ex # LLMChain + tools (файлы, тесты) — простые задачи
│   │   ├── cli_adapter.ex   # Port: claude/codex/aider в git worktree
│   │   └── result.ex        # контракт json-result, exit 0/1/2
│   ├── evaluator/
│   │   ├── judge.ex         # behaviour: evaluate(task, result) -> verdict
│   │   ├── llm_judge.ex  code_exec_judge.ex
│   │   └── verdict.ex       # score + components (не повторять разрыв ATP: только total_score)
│   ├── providers/
│   │   ├── catalog.ex       # priv/catalog/models.toml -> структуры
│   │   └── model_factory.ex # "anthropic@claude-..." -> %ChatAnthropic{...}
│   └── telemetry.ex
├── lib/kapelle_web/         # LiveView: runs list, run detail (live-стрим), catalog, controls
├── priv/catalog/models.toml
└── config/runtime.exs       # ключи провайдеров из ENV
```

Правило границ вместо полирепо: контексты общаются **только** через публичные
функции и структуры-контракты (`Decision`, `Result`, `Verdict`); web-слой не
лезет в internals. Дешёвая страховка: `boundary` (hex-библиотека) может
энфорсить это на компиляции — включить с M2.

## 4. Пошаговый бутстрап (M0 ≡ S0/KAP-001 battle-testing-пилота)

> Обновлено 2026-08-04 (v2): репозиторий и remote **уже существуют**
> (`~/labs/kapelle`, один коммит с README, синхронен с origin) — шаг `git init` +
> `gh repo create` не нужен, а `mix phx.new kapelle` буквально не выполнится.
> Baseline-тулчейн — фактический системный: **Erlang/OTP 28 + Elixir 1.19.4**
> (не 27/1.18 из ранней редакции); совместимость зависимостей подтверждает
> M0-smoke, а не текст плана.

```bash
# 1. Тулчейн
mix local.hex --force && mix archive.install hex phx_new --force

# 2. Phoenix в СУЩЕСТВУЮЩИЙ репо (phx.new спросит подтверждение на непустой
#    каталог и перезапись README.md — соглашаемся)
cd /Users/Andrei_Shtanakov/labs
mix phx.new kapelle --no-mailer      # Postgres + LiveView по умолчанию

# 3. Зафиксировать фактические версии как декларацию воспроизводимости
#    (системная установка остаётся исполнителем)
cd kapelle
printf 'erlang 28\nelixir 1.19.4-otp-28\n' > .tool-versions

# 4. Зависимости
# mix.exs: {:langchain, "~> 0.9"}, {:oban, "~> 2.19"}, {:credo, "~> 1.7", only: [:dev, :test]}
mix deps.get

# 5. Oban: миграция + конфиг очередей
mix ecto.gen.migration add_oban_jobs_table   # Oban.Migration.up()
# config.exs: config :kapelle, Oban, repo: Kapelle.Repo,
#   queues: [orchestrator: 5, executor: 10, evaluator: 5]

# 6. Ключи провайдеров (config/runtime.exs)
# config :langchain, :anthropic_key, System.get_env("ANTHROPIC_API_KEY")
# config :langchain, openai_key: System.get_env("OPENAI_API_KEY")
# config :langchain, :google_ai_key, System.get_env("GOOGLE_API_KEY")

# 7. Baseline-проверки (provider calls НЕ требуются — первый провайдер = KAP-007)
# mix deps.get && mix compile && mix ecto.create && mix ecto.migrate
# mix test && mix format --check-formatted

# 8. CI: .github/workflows/ci.yml — mix format --check-formatted, credo, mix test (postgres service)

# 9. ОДИН baseline commit — только после того, как все проверки шага 7 зелёные;
#    push в kapelle/master — отдельно, после просмотра итогового diff
```

## 5. Майлстоуны

| # | Содержание | Definition of done |
|---|---|---|
| M0 | Скелет: phx.new, Oban, langchain, CI — **без provider calls** | зависимости компилируются на OTP 28 / Elixir 1.19.4; Oban запускается с PostgreSQL; `mix test` и format-check зелёные; provider calls не требуются (первый реальный провайдер — KAP-007) |
| M1 | **Вертикальный срез**: `Run` из одной задачи → RulesPolicy → ChainAdapter (tools: read_file/write_file/run_cmd в sandbox-каталоге) → LlmJudge → вердикт в БД. Разрезан на leaf-задачи KAP-002..KAP-007 (см. battle-testing-pilot v2 §3) — каждая с детерминированной проверкой, исполняется через spec-runner | e2e-тест: submit → verdict; всё через Oban |
| M2 | Providers-каталог (`models.toml`), фабрика моделей, fallback провайдера при ошибке; `boundary` на контексты | смена модели = правка toml; провайдер-даун не валит run |
| M3 | Dashboard LiveView: список runs, страница run с live-стримом (callbacks LLMChain → PubSub), cancel/retry | видно выполнение в реальном времени |
| M4 | DAG: задачи с зависимостями, параллельные ветки, retry-политика на шаг | run из 5+ задач с ромбовидной зависимостью |
| M5 | `CliAgentAdapter`: Port + git worktree + `TRACEPARENT`; контракт json-result/exit-коды общий с ChainAdapter | реальная кодинг-задача через Claude Code из дашборда |
| M6 | Распределение: вторая нода с Oban-воркерами очереди `executor`; libcluster + PubSub между нодами | задачи исполняются на обеих нодах, дашборд видит обе |
| M7+ | Обучаемый роутер (статистика outcomes → веса), бенчмарки, отдельные execution-ноды | — |

## 6. Риски и критическая оценка (альтернативы)

| # | Риск/решение | Оценка |
|---|---|---|
| R-1 | **Oban vs чистый OTP** для распределения | Правильный старт: очередь переживает рестарты (durability), ретраи/uniqueness бесплатно. Чистые GenServer/Horde теряют in-flight state и требуют кластер с день 1. Кластер добавляется поверх Oban (M6), обратное — больно. |
| R-2 | **Свой кодировщик на LLMChain** — ловушка скоупа: agent loop, редактирование файлов, контекст-менеджмент — это отдельный большой продукт | Абстракция Executor выбрана верно, но порядок важен: ChainAdapter ограничить «малыми» задачами (генерация функции, правка одного файла, ответ по коду), реальный кодинг — CliAgentAdapter (M5). Не пытаться догнать Claude Code внутри LLMChain. |
| R-3 | **Elixir LangChain моложе Python-стека**: меньше провайдеров/фич, minor-версии ломают API (0.x) | Пиновать `~> 0.9`, изолировать все вызовы langchain внутри `Providers`/`ChainAdapter` — при поломке API чинится 2 модуля, не весь код. Альтернатива (Req + свои клиенты) даёт контроль, но дублирует tools/streaming/usage-подсчёт — не стоит того на старте. |
| R-4 | **Один проект с контекстами vs umbrella**: границы держатся дисциплиной | `boundary` с M2 + структуры-контракты. Umbrella не даёт реальной изоляции (общие deps/config), а полирепо на нулевой кодовой базе — чистый налог: экосистема пришла к вендорингу и drift-чекерам *потому что* репо много; здесь их один. |
| R-5 | **Незамкнутая петля роутера** — главный разомкнутый участок и в экосистеме (production→re-rank отсутствует, `structure-a.md` §6) | Заложить с M1: каждый `Decision` пишется с `decision_id`, каждый `Verdict` репортится обратно (`report_outcome`-паттерн arbiter). Даже если v1-роутер — три if-а, данные для обучения копятся с первого дня. |
| R-6 | Соблазн переносить governance/спеки экосистемы | Не сейчас. Независимому продукту нужен работающий контур, не гейты. Вернуться после M4, если появится второй контрибьютор. |

## 7. Связь с экосистемой (правила гигиены)

- Разработка ведётся **вне** `all_ai_orchestrators/`; соседние репо — read-only
  референс (правило `prograph-vault/authored/rules/repo-boundaries.md` де-факто
  распространяется и на чтение из нового проекта).
- Ничего не вендорим из экосистемы: продукт независимый, совместимость с
  ATP/arbiter-контрактами — не цель. Если позже захочется говорить с ATP —
  добавить адаптер, контракты (`json-result`, exit-коды) уже совместимы по духу.
- Идеи, которые захочется вернуть в экосистему (например, находки по Oban-DAG),
  фиксировать заметкой в `prograph-vault/authored/notes/` через обычный PR-флоу.

## 8. Догфудинг: разработка kapelle силами экосистемы (добавлено 2026-08-04)

Kapelle — внешний репо без контрактных связей с экосистемой, то есть чистый
догфудинг-кандидат (тот же ход, что research-bench Stage A поверх
немодифицированных Maestro/spec-runner). Подключать инструменты ступенчато:

> Обновлено 2026-08-04 (v2, синхронно с battle-testing-pilot): граница «руками vs
> инструментами» сдвинута с «конец M1» на «конец M0». Скелет (S0/KAP-001) — руками,
> но M1 уже хорошо специфицируется (контракты, policy, judges — leaf-задачи
> KAP-002+ с `mix test`), поэтому идёт через spec-runner с первого таска.

| Этап kapelle | Инструменты экосистемы | Обоснование |
|---|---|---|
| M0 (≡ S0/KAP-001) | нет (Claude Code вручную в репо kapelle) | bootstrap-неопределённость: скелет не специфицируется заранее, сбои трудно атрибутировать; это ещё и обучение Elixir/OTP руками |
| M1 (KAP-002+) — M2 | **spec-runner**: спеки в kapelle-репо, `test_command: mix test` | один инструмент, понятный контракт, exit 0/1/2 совпадает с mix-конвенциями; дешёвая точка входа; каждая KAP-задача = детерминированная проверка |
| M3+ | **maestro**: project.yaml, worktrees, параллельные workstreams (дашборд ∥ адаптеры ∥ judges); arbiter — сначала shadow route_task (S2.5) | Maestro окупается только на DAG с параллелизмом — он появляется с M3 |
| всё время | friction log (kapelle/docs/ или `_cowork_output/`) | расхождения контрактов и Python-предположения экосистемы — ценный выход догфудинга сам по себе |
| никогда (пока соло) | steward/discovery/governance-гейты | церемония без второго контрибьютора — anti-pattern gate экосистемы |

Правила гигиены сохраняются: спеки kapelle живут в kapelle-репо (не в зонтике);
экосистемные репо остаются read-only; находки по багам/фрикции экосистемы —
handoff в `prograph-vault/authored/notes/` через обычный флоу.

## Рекомендуемые действия

1. **[kapelle]** Имя выбрано: `kapelle` (2026-08-04; рассматривались также
   `battuta`, `tutti`, `podium`). Проверить доступность на hex.pm/GitHub и
   выполнить M0 по §4 — это один вечер.
2. **[kapelle]** M1 вертикальный срез до любых украшений: критерий — e2e-тест
   submit→verdict через Oban.
3. **[kapelle]** С первого коммита: контракт `Result` (json + exit 0/1/2) и
   `decision_id`→`outcome` петля (R-5) — это дешевле всего сейчас.
4. **[all_ai_orchestrators]** Ничего менять не нужно; при желании — короткая
   заметка в `prograph-vault/authored/notes/` о старте внешнего Elixir-эксперимента,
   чтобы Robin/дайджесты о нём знали.
