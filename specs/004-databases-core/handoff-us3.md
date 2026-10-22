# Передача: US3 «Вид» (T076–T085)

Ветка `004-us3`, worktree `/Volumes/YurySSD/Мои приложения/MyNotion-004-us3`.
Общая ветка с US2 подтянута (`52baa29`); безопасные сценарии iMac из US4 приняты (`9337fd0`, исходный `6a07c09`).
Основной checkout и интеграционная ветка не изменялись. Субагенты не запускались.

## Состояние передачи после независимых проверок

Собственные последние правки — `895fb3f`; общая `0240ecc` подтянута merge `287414d` без конфликтов.
Merge добавил только ранее проверенные hover/cover unit и их отчёт; product-исходники после зелёных 265 не менялись.
**265/57 unit PASS**, Release no-window SQL probe **1/1 PASS**. Слот освобождён, своих pending прогонов нет.
T079/T084/T085 остаются открыты: текущий основной UI, свежая галерея исправлений, live Notion и сравнение
бюджетов ждут ручного unlock iMac и согласования GUI с US4/hover. Прежние превышения50/100мс сохранены.
Координатор интегрирует после US4; основной checkout агент US3 не менял.

Для будущего контроля подготовлен исходный архив общей0240ecc, не checkout/worktree;
`.us3-control.tar` и `.us3-control-revision` намеренно не коммитятся. Перед сравнением после US4 обновить из этой папки:

```sh
git archive 004-databases-core App Packages PerformanceTests UITests scripts project.yml .gitignore > .us3-control.tar
git rev-parse 004-databases-core > .us3-control-revision
scripts/imac/run-on-imac.sh lock -- zsh scripts/imac/us3-validation.zsh --skip-unit
```

Последняя команда только после подтверждённого unlock и согласования очереди. В том же GUI-слоте проверить
`build/us3-validation/{desktop.png,windows.json}`; при чистом экране создать `continue`, иначе `abort`.
`--skip-unit` разрешён только без новых product-правок после текущих зелёных units; сборки UI/Release обычные.

## Реализация

Сохранены операции вида, простые и расширенные фильтры, несколько сортировок, поиск, вкладки и их меню,
видимость колонок, группировка и состояние групп, итоги колонок/групп, перенос текста, галерея `view-*`.

Продолжение Codex (`aa2d4d5`):

- `ViewBarView`: присваивание прежних `tabs`, `showsTabs`, `isInline` не снимает поле поиска с окна и не сбрасывает фокус.
  Изменение значений по-прежнему пересобирает строку вида.
- `DatabaseOperations.writeRow`: первый живой вариант группы статуса `todo` ставится новой строке по умолчанию.
  Значения фильтра/группы записываются поверх; явная пустота фильтра и группы «Нет статуса» подавляет начальный вариант.
- UI-сценарий расширен: второй уровень сортировки, поиск по буквам и правка в середине строки, статус в длинной панели,
  второй вид, обновление вкладок после переименования/перезапуска, вложенная группа расширенного фильтра и отмена;
  отдельный сценарий поиска во встроенной базе.
- В бюджетном тесте исправлен неверный предел открытия рабочего вида: **50 мс**, а не 100 мс.
  Добавлена проверка худшего кадра прокрутки **50 мс**. Прежние 58,1 мс считаются превышением.

## Проверено на iMac

- Красный прогон `NewRowDefaultsTests` до реализации: 8 тестов, новый тест падает на отсутствии начального статуса
  до и после отмены/возврата (`/tmp/us3-defaults-red.log`).
- После реализации: **261 тест в 56 наборах зелёные**, фильтр
  `DatabasesTests|DatabaseGridTests|DatabaseViewBarTests|DatabaseRowPageTests|UIGalleryTests`;
  `/tmp/us3-unit-codex.log`. Включены пустой статус, приоритет фильтра/группы, отмена/возврат.
- Первый UI-прогон выявил потерю фокуса поиска, исправленную в `aa2d4d5`:
  `/tmp/us3-ui-codex/uitest.log`, снимки `/tmp/us3-ui-codex/attachments/`.
  Этот первый запуск ещё использовал унаследованный `close_stale_prompts` с `pkill SecurityAgent`; наличие и фактическое
  завершение такого процесса журнал не фиксировал. После обнаружения принят безопасный патч `9337fd0`; последующие
  прогоны системные процессы не завершают. Самостоятельных команд завершения чужих процессов не выполнялось.
- Повтор UI снят только со своей очереди до запуска (код 130), когда координатор сообщил о TCC камеры
  YKVidRecorder поверх предупреждения ChatGPT от CoreServicesUIAgent. Это не падение кода.

## Ограничения

Живой Notion проверен на доступность через Aside, но единственный профиль `u0 / Profile 0` не подключён к браузеру.
Данные Notion не менялись; живая визуальная сверка остаётся непроверенной.

Полный прогон всех тестов перед общей интеграцией — за координатором. Каждая сборка/проверка этого продолжения шла
на iMac через `imac-run --no-fallback --wait 1800`, не больше 4 потоков; приложение на основном Mac и Cua VM не запускались.

## Первый свежий круг бюджетов после US2

`/tmp/us3-budget-codex/uitest.log`: 4 теста / 9 неуспешных проверок, exit 65. Полная таблица — quickstart.md.
Фильтр 128,0 мс > 100; открытие 111,8 мс > 50. Сортировка 69,0, группировка 83,6, видимость 85,6, поиск 30,6;
прокрутка p95 15,9 / max 39,5 мс укладываются. Набор и переходы прошли; запуск и вкладки не прошли, в том числе
возврат прокрутки 87/110 и прирост живой кучи 90,1 МБ при пределе 5 МБ.
Контекст нагрузки `/tmp/us3-budget-context.log`: load21,08/45,87/58,91, сторонний node389%CPU, mds_stores114%, Simulator.
Это не доказывает причину или регрессию US3. Пороги не ослаблялись, T085 не закрыта.
Снимок `/tmp/us3-budget-codex/probe-shots/us3-группы-перенос.png`: ячейки есть, фон прозрачный; полная галерея ещё нужна.

GUI-очередь после этого круга уступлена US4. Перед следующим кликающим прогоном в своём слоте проверить актуальные
системные окна. После US4 — сопоставимые контрольные замеры общей ветки/US3 и sample-профиль собственного пути
до оптимизаций. Формат хранения и миграции не менялись.

## Свежая GUI-серия после US4 и hover (22.10, 09:58–10:11 iMac)

Системных TCC/ChatGPT окон на preflight нет (`/tmp/us3-review-codex/desktop.png`).
`ViewFilterSortGroupTests`: 2 теста, 1 ошибка. Inline-поиск прошёл (78,2 с): посимвольный ввод, вставка в середину и Esc.
Основной сценарий прошёл фильтр, две сортировки, поиск/курсор/Esc и скрытие трёх колонок; остановился на
AX-локаторе `grouping-window` (NSView страницы отсутствует в AX). Разбор полного AX-снимка затем выявил также
**ошибку продукта**: панель и её scrollView высотой 276452 pt, по полной высоте документа. Прежняя атрибуция
только локатору была неполной. Панель переносится в window overlay по видимой области таблицы; проверяются resize
и закрытие при удалении host/смене базы. Исправлен выбор доступной области прокрутки,
для расширенного фильтра также ожидается реальная кнопка свойства. Эти новые локаторы ещё требуют прогона.
Логи и вложения: `/tmp/us3-review-codex/ui/`.

Галерея выполнилась без ошибок: `/tmp/us3-gallery-codex/`, 14 состояний × 2 темы (28 PNG), окно 1440×900 pt, PNG 2880×1800 px.
Просмотр выявил неверную заливку вложенной группы: `withAlphaComponent(0.4)` заменял исходную alpha палитры 5% / 5,5%.
Оставлен исходный `Palette.hoverBackground`; повтор снимка ещё предстоит. Fixture группированной таблицы ограничен
числовым фильтром «Часы < 2», чтобы в кадре находились итоги, а не 43 строки первой группы; повтор также предстоит.

На iMac проверен установленный Notion 4.21.1: поиск помечен `Search offline pages…`, запрос `MyNotion` дал
`No results / Go online for more results.` Тестовая база недоступна в локальном кеше. T084 остаётся открытой,
живое сравнение не засчитывается. Пользовательские страницы не изменялись; частные снимки Notion не включены в галерею.
AX-доказательство хранится локально в `/tmp/us3-review-codex/native/notion-query-result.json`.

Причина потери кеша сборки установлена отдельным dry-run (`/tmp/us3-sync-probe.log`): штатный openrsync с
`--delete --filter=':- .gitignore'` всё равно удаляет build/. Проверка штатного `P .imac-runner-*` защитила каталог,
а build-symlink удалила. После завершения текущих сборок только собственный build перемещён в
`.imac-runner-us3-build` внутри собственной runner-копии, build ссылается туда. При новом sync ссылка восстанавливается;
каждая правка всё равно проходит обычный incremental `build-for-testing`. Общие runner/очередь не изменены.

## No-GUI профиль при заблокированном экране

После прямой пробы hover экран iMac заблокирован: `CGSSessionScreenIsLocked=Yes`, SecureInput принадлежит loginwindow.
Живые UI, галерея после правок и сравнение бюджетов **не запускались** до ручного unlock. Это внешнее ограничение,
не падение MyNotion. T079/T084/T085 открыты. Общая функциональность US4 ещё не интегрирована.

Release `build-for-testing -jobs 4` прошёл на iMac. `DatabaseViewQueryProfileTests` — opt-in тест без NSWindow,
запуска приложения и ввода: копия эталона v3, повтор `ViewQuery.present` рабочего вида, сверка строк и групп.
Первый круг: PASS, 358 повторов / 14,738 с; sample не получен (поиск PID через ps не нашёл реальный XCTest Agent).
`/tmp/us3-query-profile-codex/`. Скрипт исправлен: ready.json от самого теста содержит PID и bundle;
перед sample проверяется совпадение realpath bundle. Чужие процессы не выбираются.
Второй круг: PASS, 239 повторов / 14,697 с, sample получен (`/tmp/us3-query-profile-codex2/sample.txt`, PID 52423).
Оба круга подтвердили **10000 задач, 10000 значений статуса, 1592 строки после фильтра, 7 групп**.
Число повторов под sample не является приёмочным временем.

В 4064 выборках главного потока: `ViewQuery.present` — 4051; SQL-ветка — 2627 (≈65%), из них
`ViewQuerySQL.fetch` 2548, `sqlite3_step` 2512; одна ветка B-tree/page reads содержит 407 `pread`.
Ветка чтения PropertyValues — 1016 (≈25%), ветка UUID — 375 (≈9% общего). Декодер не основная причина.
Контекст второго круга: load40,32 до сборки / 50,44 при sample; сторонний node383%CPU, ANECompilerService,
Simulator. Это не доказательство причины прежнего превышения и не сравнение общей ветки с US3.

После профиля scoped правка: только select/status в `PropertyValues.read` повторно использует существующий
`ViewQuerySQL.uuid`; SQL, формат хранения и миграции не меняются. Добавлены differential-проверки с Foundation:
правильные lower/upper/mixed/all-zero/all-FF, повреждение каждой позиции и длины, пробелы, braces,
форма без дефисов, Unicode и NUL. Проверки прошли в повторе `/tmp/us3-lifecycle-green.log` (см. уточнение ниже).
US4 подтвердил свой `28cd4b5`: только `ComputationHook.aliveRowsSQL`, выбор PK через `+parentId`.
ViewQuery SQL не менялся; до точного EXPLAIN дальнейшей оптимизации SQL нет. Проба умеет сохранить точные
SQL/аргументы/план в ready.json, `us3-query-profile.zsh --no-sample` — диагностический круг без sample;
он также не заменяет бюджет открытия нарисованного вида.

Доработано закрытие ViewPanels: якорь слабый (таблица удерживает presenter через callbacks), карточки закрываются
при освобождении. Добавлен regression освобождения host/presenter без показа карточки. Панель ограничена
`host.visibleRect.intersection(host.bounds)` до conversion и окном после неё; это учитывает macOS14+,
где `clipsToBounds` по умолчанию false (согласовано с US4). Главная страница настроек прокручивается и у host150pt.
Проверяются scroll200000, resize, удаление host, повторное открытие и освобождение overlay. Ни один unit не вызывает
orderFront/makeKey/input. В старой галерее обеих тем выбранный checkbox был сплошным квадратом: локально в US3
два слоя рисуются раздельно, общий ActionMenuIcon не меняется; свежий снимок пока pending.

Манифест старой галереи проверен: 28 записей, 14 состояний × 2 темы, все файлы на месте, окно1440×900pt,
PNG2880×1800px. Путь `/tmp/us3-gallery-codex/`. Новые состояния после правок ещё не отсняты.

Уточнение текущего повтора: `/tmp/us3-unit-codex2.log` завершился SIGABRT, набор не принят.
`.ips` (`/tmp/us3-unit-codex2-crash.ips`) локализует аварийное чтение unowned в отражении Swift Testing
проваленного `#expect(orphan == nil)` после deinit presenter. Lifecycle-сценарий сохранён;
для адресного red-повтора проверяется Boolean без отражения объекта. Причина удержания панели
ещё исследуется; 265 тестов не объявляются пройденными. Живой UI остаётся заблокирован экраном iMac.

Lifecycle red→green (22.10): `/tmp/us3-lifecycle-red.log` — 1 тест / 1 failed expectation,
без SIGABRT после проверки Boolean. Presenter освобождается и overlay удаляется немедленно;
провалена только проверка weak-панели до дренирования AppKit autorelease pool. Fixture исправлен:
владелец не удерживается, после его deinit отправляются resize/update/willClose notifications,
weak-панель проверяется после autoreleasepool. Product-код между red/green не менялся.
Адресный green: **4 теста / 2 набора, PASS 0,429 с**, включая lifetime, слабый якорь и UUID differential.
Затем **265 тестов / 57 наборов, PASS 14,752 с**, пять затронутых модулей,
`/tmp/us3-lifecycle-green.log`, exit0. Lifecycle-сценарий сохранён и усилен.
SIGABRT первого прогона — чтение unowned из диагностического Mirror преждевременного failed expectation;
после штатного pool панель освобождается, уведомления не вызывают обращений к освобождённому presenter.
Это подтверждение unit-пути, живые UI/галерея и бюджет после правок остаются непроверенными.

No-GUI Release повтор без sample: **1/1 PASS 14,681 с**, 373 повтора (не приёмочное время),
`/tmp/us3-query-nosample-fetch/build/us3-query-profile/{ready.json,test.log,context.log,build.log}`.
Обычный build-for-testing прошёл до запуска; sampled=0, no_sample=1, test_exit=0.
Эталон снова: 10000 задач / 10000 статусов / 1592 строки / 7 групп. Точный план сохранён:
`page_by_parent(parentId=?)`; covering indexes db_cell по property+text и property+number;
LIKE-подзапрос пользуется text-index только по propertyId; два LEFT JOIN db_computed — PRIMARY KEY
(rowId,propertyId), db_row_order — индекс(viewId,rowId), затем TEMP B-TREE FOR ORDER BY.
Это иной запрос, чем US4 aliveRows(id IN batch500): здесь AND с NOT IN и OR(date-range, multiSelect LIKE),
поэтому перенос +parentId/PK-плана без отдельного доказательства не выполнялся. SQL не изменён.
Профиль устанавливает SQL как главную ветку, но не выделяет виновный оператор; относить всю стоимость
к LIKE или ORDER BY по одному EXPLAIN нельзя. Load24,86/44,17/55,60, сторонний node369%CPU;
ни сравнение общей ветки с US3, ни бюджет50мс этим прогоном не подтверждены.

## Совместная проверка US4 + US3 после интеграции (22.10, iMac 12:28–12:33)

Проверен ровно merged HEAD `4eca0a205cc1874b9ce835ab82a1f63d118c4f14`, fast-forward в прежней
`MyNotion-004-us3`. До прогона runner сверил SHA256 **1007 tracked файлов** App/Packages/PerformanceTests/
UITests/scripts/project.yml с локальным merged HEAD: все OK. Исходники в процессе не менялись.
Один последовательный `imac-run --no-fallback --no-setup --wait 1800`, jobs4; собственный защищённый кеш
`.imac-runner-us3-build`, восстановлен только build-symlink. Основной checkout не менялся.

- `swift test --scratch-path ../../build/us3-swiftpm --jobs 4 --filter
  "DatabasesTests|DatabaseGridTests|DatabaseViewBarTests|DatabaseRowPageTests|UIGalleryTests|FormulasTests|SyncTests|NotesCoreTests"`
  — **680 тестов / 120 наборов PASS 29,324 с**, exit0. Formula/BackgroundRecompute и BackgroundTypeChange
  включены через DatabasesTests; проверены также NotesTransaction/Sync по влиянию US4.
- Затем обычный `xcodegen generate -q` и `xcodebuild -scheme MyNotion -configuration Debug
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/imac-uitest-dd -jobs 4 build-for-testing -quiet`
  — **exit0**. Есть compiler warnings и предупреждения о stale cache files, ошибок сборки нет.
  Приложение и UI-тесты не запускались, test-without-building не применялся.
- Ручная проверка слияния: оба gallery handlers/tearDown и catalog/cases сохранены; Cells registry содержит
  US2 Option/Date/Files popup и US4 Relation popup, Relation/Rollup grid types; начальный todo статус в writeRow
  и US4 erasedLinks в NotesTransaction сохранены. US3 ViewPanels/ViewSettingsPanel совпадают с895fb3f;
  PropertyMenuPresenter сохраняет US4 overlay/lifecycle и US3 действия фильтра/сортировки/итогов/setViewId.
  Соответствующие registry/default-row/relation/presenter tests входят в зелёный joint набор.

Артефакты `/tmp/us3-joint-4eca0a2/build/us3-joint-4eca0a2/`: `unit.log`, `build.log`, `unit.exit`, `build.exit`,
`source-check.log`, `expected-source.sha256`, `revision.txt`, `context.log`, `xcodegen.log`.
Общий журнал `/tmp/us3-joint-4eca0a2-run.log`. macOS27.0.1, Xcode26.6; load до11,25/44,78/59,78,
после59,59/49,50/56,71. Это проверка корректности/компиляции, не измерение бюджета.

Scoped исправлений после слияния не потребовалось. Бюджеты US4 повторно не запускались.
T079/T084/T085 и живые UI/галерея/контроль US3 не засчитаны: подтверждения unlock нет, живых проб не было.
Прежний локальный контрольный архив0240ecc сейчас устарел и не использовался. После интеграции сравнивать
текущую общую ветку с самой собой бессмысленно; для выяснения регрессии US3 контрольной ревизией после US4
служит `9b4b05d` (если координатор не выберет другой baseline), исследуемая merged ревизия — `4eca0a2`.

## Возобновление GUI: экран разблокирован, новая блокировка Xcode (22.10, 14:42)

Координатор подтвердил loginDone/onConsole=Yes, отсутствие ScreenIsLocked; hover выполнил свою первую серию
и передал GUI US3. US3 живую серию **не запускал**: после обновления Xcode US4 обнаружил build exit69
до компиляции, сообщение требует принять лицензионные соглашения. Свежая read-only проверка US3:
`xcode-select -p` → `/Users/ykurilov/Applications/Xcode.app/Contents/Developer`, Xcode27.1 build27A9275;
`xcodebuild -version` exit0, `xcodebuild -checkFirstLaunchStatus` exit69.
Лог `/tmp/us3-xcode-license-4961489.log`. Лицензия, блокировка экрана, чужие процессы не менялись.
Это новый toolchain blocker, а не прежний lockscreen и не результат проверки MyNotion.
Принятая joint проверка680/build относится к Xcode26.6; свежей проверкой27.1 её не подменяем.

Common4961489 и безопасный fail-fast patch a7a298c подтянуты (локальный merge e7ab212).
Product исходники остаются merged4eca0a2. До получения подтверждения устранения Xcode blocker новых
сборок/GUI jobs не ставили; своих pending/занятых слотов нет. T079/T084/T085 остаются открыты.

Подготовлены, но ещё не выполнены изменения harness:
- `us3-validation.zsh --skip-unit`: оба main/inline теста ViewFilterSortGroupTests,28 gallery view PNG,
  обычный view budget, контроль; принятые680units/US4budgets не повторяются. Предыдущий SQLsample без новой
  гипотезы не повторяется. Перед preflight toolchain-status guard, свежие результаты изолированы от старых.
- Baseline архив точно9b4b05d (`.us3-control-revision`), merged product4eca0a2; в обеих контрольных копиях
  один безопасный lib/on-imac harness a7a298c. Product baseline и тестовые пороги не меняются.
- Уникальный выход `build/us3-validation-4961489-<timestamp>`, путь в `build/us3-validation-current`;
  перед `continue` прочитать desktop/windows именно в нём; при перекрытии/блокировке `abort`.
  Выход control — `build/us3-control-results-9b4b05d-vs-4eca0a2-<timestamp>`, pointer `build/us3-control-current`.

После подтверждения восстановления Xcode согласовать свободный GUI, выполнить свежий preflight через
`scripts/imac/run-on-imac.sh lock -- zsh scripts/imac/us3-validation.zsh --skip-unit`,
затем передать экран US4. Снимков новой серии US3 ещё нет. Подготовленные shell-изменения пока
проверены чтением/diff-check; фактический прогон harness после blocker ещё предстоит.

## После снятия toolchain blocker: prebuild PASS, повторная блокировка экрана

По поручению нового координатора d966f02a серия возобновлена; порядок hover → US3 → US4 сохранён.
На восстановленном Xcode27.1 через последовательные no-GUI jobs `imac-run --no-fallback --no-setup
--wait 1800`, jobs4, собственный protected cache выполнены:

- обычный MyNotion Debug build-for-testing: **exit0**, `/tmp/us3-live-prebuild.log`,
  `/tmp/us3-live-4961489/prebuild/debug/build.log`; перед ним firstLaunch-status успешен;
- MyNotionPerformance Release build-for-testing merged US3: **exit0**;
- тот же Release build-for-testing baseline9b4b05d: **exit0**, в том же последовательном job;
  `/tmp/us3-live-release-prebuild.log`, `/tmp/us3-live-4961489/prebuild/release/`
  (`us3.exit`, `baseline.exit`, оба build.log и xcodegen.log).

Приложения и тесты этими prebuild не запускались. Product исходники не отличаются от merged4eca0a2.
У baseline product9b4b05d; одинаковый безопасный lib/on-imac harness применён к обеим ревизиям.
Исходники LaunchAndMemoryTests/TabsPerformanceTests/TypingAndNavigationTests между ревизиями одинаковы.
Новый DatabaseViewPerformanceTests отсутствует в baseline и предназначен для отдельного обычного US3 прогона.

Пока hover первым готовил regression и живую пробу, обе Release сборки были вынесены из будущего GUI-слота.
После него hover **передал экран**, но его свежий preflight снова чёрный, ioreg содержит
`CGSSessionScreenIsLocked=Yes`, `kCGSSessionSecureInputPID=650`. Его guard exit78 **до сборки/запуска**.
Артефакты hover: iMac `/Users/ykurilov/work/shots/empty-heading-current/{preflight.png,session.txt,actions.jsonl}`;
локально `/tmp/empty-heading-preflight.png` (4480×2520, чёрный), `/tmp/empty-heading-live.log`.
US4 независимо подтвердил locked/PID650 read-only ioreg. US3 при известной блокировке GUI job не ставил,
не создавал собственный снимок и не выжидал заведомый UI timeout. CGSession/блокировка/чужие процессы не менялись.
Новая причина остановки — lockscreen; прежний Xcode license/firstLaunch blocker снят.

Основной UI, inline UI,28 gallery, ordinary view budget и control9b4b05d-vs4eca0a2 **не выполнялись**.
T079/T084/T085 остаются открыты; prebuild не подтверждает UI или бюджет. Прежние превышения50/100мс сохранены.
Своих pending/running jobs и занятых GUI слотов нет. US4 уведомлён напрямую: при подтверждённом unlock
по-прежнему ожидает передачу после US3.

Уточнение harness: галерея выполняет обычный build_app Debug в собственной `build/imac-uitest-dd`,
которую уже подготовил prebuild, вместо второго полного Debug кеша. Контекст стадий включает ps/uptime/date.
`zsh -n scripts/imac/us3-validation.zsh` и `zsh -n scripts/imac/us3-control.zsh` на iMac: **exit0**,
`/tmp/us3-live-harness-syntax.log`. Это синтаксическая проверка, фактическая полная серия ещё не выполнена.
Manifest `/tmp/us3-live-4961489/prepared-source.sha256` только подготовлен; runner source-check GUI серии
ещё не состоялся и не засчитан. Для возобновления обновить manifest при изменении source и выполнить
fresh preflight в собственном согласованном GUI-слоте; после серии передать US4.
