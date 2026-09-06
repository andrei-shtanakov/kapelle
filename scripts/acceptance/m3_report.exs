# Приёмочный прогон M3: два golden-сценария через штатный worker-контур,
# затем — настоящий CLI-отчёт `mix kapelle.product.report` по каждому.
#
# Смысл скрипта — сделать закрывающий вердикт среза воспроизводимым: приёмка
# 2026-09-06 предъявляет напечатанный блок, а не пересказывает зелёные тесты,
# и рецепт обязан исполняться, а не описываться прозой.
#
#     MIX_ENV=test MIX_TEST_PARTITION=acc mix ecto.create
#     MIX_ENV=test MIX_TEST_PARTITION=acc mix ecto.migrate
#     MIX_ENV=test MIX_TEST_PARTITION=acc mix run scripts/acceptance/m3_report.exs
#     MIX_ENV=test MIX_TEST_PARTITION=acc mix ecto.drop
#
# Только `MIX_ENV=test`: fixture-агенты — test-only модули (`test/support`,
# `elixirc_paths`). `MIX_TEST_PARTITION` даёт отдельную БД, чтобы прогон не
# смешивался с тестовой; `Sandbox.mode(:auto)` нужен, потому что вне ExUnit
# никто не берёт соединение во владение. Скрипт ничего не пишет в дерево.
#
# Скрипт fail-closed: ненулевые discard/failure у drain и любая ось, не равная
# `:pass`, роняют прогон ненулевым кодом. Приёмочный инструмент, который
# печатает красное и выходит нулём, — это зелёный гейт без гарантии.
#
# Единственное, что меняется от прогона к прогону в выводе, — `wall ms`.

alias Ecto.Adapters.SQL.Sandbox
alias Kapelle.Product.{FixtureAgent, Loop, RunVerdict, StrictParse}

Sandbox.mode(Kapelle.Repo, :auto)

# Часы прибиты, чтобы артефакты цикла были детерминированы так же, как в
# parity-тестах: приёмка сверяет вердикт, а не текущее время.
now_iso = "2026-08-12T18:00:00Z"
Application.put_env(:kapelle, :product_clock, fn -> now_iso end)

docs_for = fn workspace, glob, role ->
  workspace
  |> Path.join(glob)
  |> Path.wildcard()
  |> Enum.map(fn path ->
    {:ok, doc} = path |> File.read!() |> StrictParse.parse()
    {{role, doc["iteration"]}, doc}
  end)
end

run = fn loop_id, workspace ->
  script =
    Map.new(
      docs_for.(workspace, "rp-*.yaml", :researcher) ++
        docs_for.(workspace, "cd-*.yaml", :creator)
    )

  :ok = FixtureAgent.install_script!(loop_id, script)

  start =
    Loop.start(File.read!(Path.join(workspace, "idea.yaml")),
      loop_id: loop_id,
      proposal_id: "PP-001",
      exchange_log_id: "XL-001",
      max_iterations: 2,
      agent: "fixture:" <> loop_id,
      now_iso: now_iso
    )

  # Типизированные отказы старта разбираем сами: голый `{:ok, _} =` превратил бы
  # самую вероятную ошибку оператора — повтор рецепта по неудалённой БД — в
  # MatchError без единой строки отчёта.
  case start do
    {:ok, _row} ->
      :ok

    {:error, :already_initialized} ->
      raise "acceptance: цикл #{loop_id} уже есть в БД — остаток прошлого прогона. " <>
              "Выполните `MIX_ENV=test MIX_TEST_PARTITION=acc mix ecto.drop` " <>
              "и повторите рецепт с начала."

    {:error, reason} ->
      raise "acceptance: Loop.start(#{loop_id}) отказал: #{inspect(reason)}"
  end

  %{discard: discard, failure: failure} =
    Oban.drain_queue(queue: :product, with_recursion: true)

  IO.puts("drain #{loop_id}: discard=#{discard} failure=#{failure}")

  # Счётчики возвращаются, а не проверяются здесь: `drain_queue/1` по контракту
  # не выбрасывает наружу, и именно на красном прогоне вердикт нужнее всего —
  # discarded-джобы дают finding `:jobs_discarded`. Роняем после печати.
  %{loop_id: loop_id, discard: discard, failure: failure}
end

expect_clean_drain = fn %{loop_id: loop_id, discard: discard, failure: failure} ->
  if discard != 0 or failure != 0 do
    raise "acceptance: drain #{loop_id} не чист — discard=#{discard} failure=#{failure}"
  end
end

expect_pass = fn loop_id ->
  {:ok, verdict} = RunVerdict.for_loop(loop_id)

  if verdict.product != :pass or verdict.harness != :pass do
    raise "acceptance: #{loop_id} — product=#{verdict.product} harness=#{verdict.harness}, " <>
            "ожидались обе оси :pass"
  end

  verdict
end

# Оси — не весь предмет §9.3: потеря видимости cost/interventions прошла бы
# зелёной, а ради неё LOOP-WAIVER и выбран. Проверяем то, что предъявляем.
expect_visible = fn %{cost: cost, interventions: interventions}, loop_id, waivers ->
  if cost.iterations_used != 2 or cost.stage_jobs != 6 or is_nil(cost.wall_ms) do
    raise "acceptance: #{loop_id} — cost-блок не предъявлен: #{inspect(cost)}"
  end

  if interventions.waivers != waivers or (waivers > 0 and interventions.waiver_refs == []) do
    raise "acceptance: #{loop_id} — interventions не предъявлены: #{inspect(interventions)}"
  end
end

happy_drain = run.("LOOP-HAPPY", "test/support/fixtures/golden/happy/workspace")
waiver_drain = run.("LOOP-WAIVER", "test/support/fixtures/golden/human_waiver/workspace")

# Отчёт печатает сама Mix-задача, а не её внутренности: приёмка предъявляет ту
# поверхность, которой пользуется оператор. `rerun/2` — потому что одну и ту же
# задачу Mix во втором вызове молча пропустил бы.
IO.puts("\n$ mix kapelle.product.report LOOP-HAPPY")
Mix.Task.run("kapelle.product.report", ["LOOP-HAPPY"])

IO.puts("\n$ mix kapelle.product.report LOOP-WAIVER")
Mix.Task.rerun("kapelle.product.report", ["LOOP-WAIVER"])

# Проверки — после печати: оператор должен увидеть вердикт целиком, даже когда
# прогон падает, иначе разбирать будет нечего.
expect_clean_drain.(happy_drain)
expect_clean_drain.(waiver_drain)

expect_visible.(expect_pass.("LOOP-HAPPY"), "LOOP-HAPPY", 0)
expect_visible.(expect_pass.("LOOP-WAIVER"), "LOOP-WAIVER", 1)

IO.puts("\nacceptance: обе оси pass, cost и interventions предъявлены на обоих циклах")
