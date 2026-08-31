# CLAUDE.md

Elixir/Phoenix-оркестратор (Oban) — боевой полигон №1 контура spec-runner/Maestro и
потребитель вендоренных контрактов impresario (bounded context `Kapelle.Product`).
Операционный бэклог фаз — `spec/tasks.md`; план уровня репо — `./TODO.md`.

## Repo scope & boundaries

- **Этот репо:** `kapelle` — git-корень `all_ai_orchestrators/kapelle/`, remote `git@github.com:andrei-shtanakov/kapelle.git`.
- **Соседи (READ-ONLY reference):** все остальные подпроекты воркспейса — их код не
  редактировать. Состав флота — `ai-orchestrators-workspace/workspace-manifest.toml`
  (SSOT); рукописные списки соседей в CLAUDE.md не ведём — они дрейфуют.
- **Канон имени репо = имя каталога после обычного `git clone`** (`maestro`, `libretto`).
- Нужна правка у соседа → **стоп**: запиши handoff в `../prograph-vault/authored/notes/`
  (кросс-проектное) или `../_cowork_output/` (черновик), не трогай его файлы.
- Кросс-репные контракты — **вендорить пиненой копией внутрь**, не ссылаться наружу.
- Полное правило (SSOT): `../prograph-vault/authored/rules/repo-boundaries.md`.

## Git workflow (у репо есть remote)

- Ветка `<type>/<slug>` → push → `gh pr create`. **Прямые коммиты в `master`
  запрещены**, как и локальный мерж ветки в `master` в обход PR.
- Ревью PR: **Copilot по умолчанию НЕ запрашивается** (решение владельца 2026-08-25,
  metered-бюджет; включение — строка `Copilot-ревью: запрашивать` в этой секции или
  явная просьба владельца; на «Copilot encountered an error» НЕ перезапрашивать —
  троттлинг у кромки бюджета, перезапрос платный). Умолчание ревью с гейтом
  codex-review — терминальный цикл (решение владельца 2026-08-28): итерировать
  локально `sh scripts/review/local.sh` до чистого вердикта (подписочный codex,
  $0 API) → пушить **драфтом** (CI отвечает deferred) → приёмочное ревью
  `sh ../devtools/review-pr.sh <repo> <pr> --dry-run`, затем без `--dry-run` —
  вердикт публикуется PR-ревью от **ai-prosto**; CI-прогон после снятия драфта —
  advisory-фолбэк, его красноту/зависание не перегонять (SSOT:
  `../prograph-vault/authored/rules/git-workflow.md`).
- **Мерж — агент по умолчанию** (ADR-ECO-011 «DarkFactory», ратифицирован 2026-08-30):
  при approve ревью-контура и зелёных обязательных проверках PR мержит агент —
  `gh pr merge` **от учётки ai-prosto** (`merged_by` — наблюдаемый различитель
  agent/human, аудит `gh pr list --json mergedBy`) — и выполняет хвост чистки ниже.
  Request-changes или неприбывшее включённое ревью = `unknown` ⇒ мерж не выполняется,
  PR остаётся человеку. Человеческий мерж — opt-in: строка `Мерж: человек` в этой
  секции (здесь НЕ объявлена) либо `merge_policy` экосистемного конфига. **Всегда
  человеку, без переопределения:** PR по authority-root путям (ADR-ECO-004 I2) и PR
  без предъявленного evidence базового слоя.
- После мержа (кем бы то ни было): `git switch master && git pull --ff-only`, затем удалить
  влитую ветку в **обеих половинах**: локально `git branch -d <ветка>` (после squash-мержа
  `-d` откажется — сверить, что `git diff master <ветка>` пуст, и удалить
  `git branch -D <ветка>`) и на origin
  `git push origin --delete <ветка>`, если GitHub не удалил сам; затем `git fetch --prune`.
- Никогда не делать force-push в общие ветки; не трогать другие репо (см. scope выше).
- Полное правило (SSOT): `../prograph-vault/authored/rules/git-workflow.md`.

## Входящие запросы (inbox)

В начале работы проверь входящие: `gh issue list --label inbox --state open`.
Issue с лейблом `inbox` — запрос от соседнего репо, ещё **не** пункт плана.
Принять = завести пункт в `TODO.md` с указанным `slug:`; принял под другим
именем — поправь `slug:` в теле issue.
Отказать = `gh issue close --reason "not planned"`.
Нужна работа в соседнем репо — не редактируй его: заведи там issue
(`slug:` + `from:` + проза). Правило: ADR-ECO-006 — канон в `ecosystem-kb`
(каталог `prograph-vault/` в корне воркспейса),
`authored/decisions/2026-07-28-adr-eco-006-cross-repo-issue-inbox.md`.

Исходящее ожидание — вторая половина того же ритуала: «ждём соседа» существует
**только** как чекбокс `TODO.md` с `@blocked_by:todo://<repo>/<id>` (переходно —
`<repo>#<номер>`); память сессий, заметки и handoff-доки — лишь зеркало. Находка
PF-BLOCKER-STALE по этому репо = «ожидание доставлено — действуй или переставь тег».
Правило (SSOT): `../prograph-vault/authored/rules/cross-repo-waits.md`.

## `../_cowork_output/` — dev-only

Координационный dev-scratch воркспейса; у пользователей и клонов проекта его НЕТ.
Shipped/runtime-код никогда не читает и не резолвит пути под ним; кросс-репные
контракты вендорятся пиненой копией внутрь, не ссылкой наружу. Ссылаться на него
могут только dev-тулинг самого воркспейса и документация. Канонические факты живут
в репо-владельце (пример: SSOT agents-catalog — `atp-platform/method/agents-catalog.toml`,
ADR-ECO-003). Полное правило (SSOT): `../prograph-vault/authored/rules/cowork-output.md`.
