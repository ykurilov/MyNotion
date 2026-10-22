# Мерцание текстовых блоков при наведении: диагностика

Дата: 22.10.2026. Ветка `fix-hover-flicker`, основа `29221bb` + безопасные iMac-скрипты `de3fd75` (эквивалент `ca563af` общей ветки).

**Баг пока не исправлен. Причина не подтверждена. Исходники редактора не менялись.**

## Что проверено

- Старый `/tmp/hover-probe-1/uitest.log`: с t=40 s XCUITest фиксирует два диалога CoreServicesUIAgent; ручки не появились, тест завершился через 663 s. Это сбой воспроизведения, а не доказательство ошибки ручек.
- Актуальный снимок iMac в 09:12: `/tmp/paseo-images/hover-desktop-before.png`. Видны запрос камеры для YKVidRecorder и предупреждение macOS о ChatGPT.app. Разрешения чужого приложения не менялись, процессы не завершались.
- Объединённый прогон через `scripts/imac/run-on-imac.sh lock` (`--gui --no-fallback --wait 1800`): снимок + подготовка UI + unit-проверка. Из-за подтверждённых диалогов остановлена только собственная сборка UI (PID 45746, UI rc=143), до действий мыши. Чужие окна не закрывались. Затем в том же слоте выполнен unit-тест.
- `swift test --jobs 4 --filter HoverLayoutTests` на iMac: **1 тест прошёл, 0.291 s**. Заголовок, обычный абзац, два пункта списка, обложка и иконка; 80 прямых вызовов `mouseMoved`. Рамки всех TextKit-фрагментов и соответствие ручки блоку стабильны. Журнал: `/tmp/hover-geometry-baseline.log`, общий: `/tmp/hover-baseline.log`.

- Повтор с побайтовым сравнением снимков текста после каждого `mouseMoved`: **1 тест прошёл, 0.849 s**. Изображение заголовка, абзаца и списка оставалось неизменным во всех 80 шагах. Журнал: `/tmp/hover-pixels-baseline.log`. Этот результат относится к невидимому окну и прямым вызовам обработчика, а не к реальному движению мыши по экрану.

Гипотеза: `updateBlockHandles` вызывает `markerLine`, который делает `ensureLayout` отдельного абзаца на каждом движении. Сдвиг рамок из-за этого вызова в unit-проверке **не воспроизведён**. Удаление `ensureLayout` без подтверждения причины не делалось.

## Проба UI

`UITests/HoverFlickerProbeTests.swift` продолжает незакоммиченную пробу предыдущего агента. Исходник до изменений сохранён в `/tmp/HoverFlickerProbeTests.original.swift`.

- Лимит 180 s, остановка на первой ошибке, снимок рабочего стола и завершение собственного приложения в teardown.
- Страница с заголовком, абзацем, списком, обложкой и иконкой.
- Сравнение снимков при движении по заголовку и вниз через текст; каретка вынесена из сравниваемой области.
- Проверки ручек, меню, правки с отменой и текста на диске.

Этот расширенный UI-сценарий **ещё не выполнен**. Код пробы не является подтверждением работы редактора.

Повтор после устранения перекрывающих системных окон:

```sh
scripts/imac/run-on-imac.sh uitest \
  -only-testing:UITests/HoverFlickerProbeTests \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 180 \
  --out /tmp/hover-ui
```

## Ограничения

Прямые вызовы `mouseMoved` в невидимом окне не проверяют реальный цикл tracking areas активного окна, вход/выход мыши, поведение слоёв на экране или промежуточные кадры. Для исправления требуется воспроизведение в активном окне на iMac и подтверждение причины. Проверки ручного наведения, меню и редактирования пока не пройдены.


## Продолжение 22.10, 10:13-10:38 WITA

Исправления production-кода по-прежнему нет: обе жалобы требуют подтверждённого живого воспроизведения.

### Готовые страницы и UI

В `EditorScenarioFixture` добавлены изолированные страницы через NotesCore до запуска приложения. Для отдельной проверки перекрытия есть cover `solid_blue`, иконка, длинное название, heading, paragraph и 80 абзацев для прокрутки. Набор текста для подготовки больше не требуется.

`/tmp/hover-cover-live-2.log`, `/tmp/hover-cover-live-2/attachments/`:

- `CoverTextOverlapTests`: начальная геометрия cover/title/icon и наличие ручки первого блока прошли; затем XCTest остановился на `page-tree.hover(): Not hittable`. Снимок пикселей, scroll, resize и return **не выполнены**. Начальную геометрию нельзя распространять на остальные состояния.
- `HoverFlickerProbeTests`: после клика под последним пунктом не нашёл ручки; медленные проходы, сравнение текста, меню и редактирование **не выполнены**. На финальном PNG виден correction-popup около `dsa`. Это ошибка подготовки/управления пробой, не доказательство отсутствия мерцания.
- Снимок последней пробы: `/tmp/hover-cover-live-2/attachments/915ABDE7-15CA-4E5E-A4C6-2EDAF01B1757.png`.

### Прямая CuaDriver серия

Согласована с US3 после освобождения US4; запуск через `run-on-imac.sh lock`, no-fallback, wait 1800. Приложение Debug собрано только на iMac с jobs 4. Синхронизация удалила прежний `build/`; собственный восстановленный кеш сохранён в `.imac-runner-hover-build`, `build` ссылается на него. Новая база `~/work/shots/hover-direct/probe.sqlite` создана через существующий VisualSamplePage, затем при закрытом приложении в неё добавлена синяя обложка. До проверки текст не вводился.

Живой проход остановлен до движения мыши: CuaDriver вернул полностью чёрный desktop PNG 4480x2520, `bring_to_front` не подтвердил фокус (`workspace_frontmost_pid=650`), `get_window_state` вернул `ax_window_unresolved`, 0 AXWindow. MyNotion PID12498 жив, WindowServer видел собственное окно2549; отсутствие AX относится ко всем приложениям. `ioreg` подтвердил `CGSSessionScreenIsLocked=Yes`, `SecureInputPID=650` (loginwindow). `check_permissions`: Accessibility=true, Screen Recording=true; `health_report`: overall=ok, AX trusted. Новых MyNotion crashlog не найдено. GUI-слот освобождён, US3 и координатор предупреждены. Требуется ручная разблокировка сеанса; вслепую клики не выполнялись.

Ошибка диагностики: после уже наблюдённого чёрного кадра в команду ошибочно попал `CGSession -suspend`, который не является читающим. Команда могла повторно закрепить блокировку; координатор уведомлён. Состояние сеанса далее не менялось, TCC и чужие процессы не трогались.

Артефакты: `/tmp/hover-direct.log`, `/tmp/hover-direct-desktop.png`, `/tmp/hover-direct-artifacts/hover-direct/{health.json,permissions.json,ioreg.txt,processes.txt,result-1.json,desktop-current.png}`. Служебный `seed.png` снят до добавления cover; он не доказывает отсутствие перекрытия.

Следующий живой проход после разблокировки: подтвердить активность и масштаб, Esc и визуальное отсутствие correction, реальные движения по видимому heading/paragraph с кадрами; затем реальные scroll/resize/return. Не считать отсутствие доступных ручек или AX успешной проверкой. Гипотезы mouseMoved/ensureLayout и inset/cache обложки остаются отдельными.


### Отдельная проверка кеша обложки без GUI

`imac-run --no-sync --no-fallback --wait 1800`, `swift test --jobs 4 --filter CoverCacheLayoutTests` на iMac: **1 тест, 2 варианта (иконка есть/нет), прошёл за 1.348 s**. Сначала нарисовано тело без обложки, затем setCover(height:280), ширина1200→900→1200; во всех шести состояниях тёмных пикселей на обложке вне иконки0, название ниже обложки. Журнал `/tmp/cover-cache-final.log` (сборка162.25s, rc0). Простая гипотеза stale rendered text после setCover/resize в невидимом fixture не подтвердилась. Реальное прокручивание и возврат страницы эта проверка не покрывает.


## Разблокированный iMac, 22.10, 14:40-14:46 WITA

В собственную ветку влит общий `4961489` (merge `556cc39`), fixtures сохранены. В одном согласованном проходе и его ограниченном продолжении использован GUI queue no-fallback. Новая incremental сборка **НЕ состоялась**: Xcode27.1 требует принятия лицензии (реальный текст в `/tmp/hover-live-unlocked.log`). `build_app` возвратил0 из-за последнего присваивания APP; координатор уведомлён, US4 отдельно исправил fail-fast. Запущен прежний сохранённый Debug app, поэтому приведённые ниже наблюдения являются baseline старого приложения, **не проверкой merged4961489**. Новых сборок при отсутствии лицензии не запускали.

### Реальное движение и снимки

Свежая изолированная база, существующий VisualSamplePage, без ввода текста. Видимость окна подтверждена desktop PNG и AX (окно2629, процесс22770); после нативного клика по заголовку и Escape correction отсутствовала. `move_cursor(scope:desktop)` физически переместил указатель по видимому heading1 и следующему paragraph:26 точек, get_cursor_position подтвердил конечные позиции720/835 и720/883 points. Форма текста на просмотренных кадрах стабильна; ручки над этими строками не появились, поэтому полная работа hover не засчитана. Транспортная гонка SCP (сценарий прочитал ещё пустой command3.json) прервала первую серию до scroll. Остаток выполнен одним конечным скриптом без сборки и интерактивных command-файлов, по согласованию с US3.

Уточнение Юрия по настоящему снимку: проблема под обложкой — пересечение серой строки «Заголовок 2» с крупным page-title. Dark-pixels-inside-cover тест этого не покрывает.

В продолжении создана отдельная база `~/work/shots/hover-exact/exact.sqlite`: page-title «Заголовок 2», no icon, first heading2 с текстом «Заголовок 2», cover gradients_8, width1740. **Отличия от снимка Юрия:** gradients_8 оказался бирюзово-коралловым, не фиолетовым; first heading заполнен, хотя серая строка у Юрия может оказаться подсказкой ПУСТОГО heading. Поэтому точное воспроизведение ещё не достигнуто.

- Начальное окно: AX page-title frame x796.5,y519,w718,h50 (desktop points). По пикселям чёрные буквы title занимают y530…559, bodyheading y597…614: строки не пересекаются.
-24 реальных moves в продолжении; область desktop x1580…3050,y1010…1390 native pixels включает title/firstheading. Все6 кадров наведения побайтно совпадают с initial (число пикселей с разницей>8 равно0). Native cursor подтверждён. Это исключает наблюдённую деформацию в данных дискретных кадрах, но не кратковременные изменения между ними.
- Реальная прокрутка вниз10 и вверх50 lines выполнена: на scroll.png обложка/текст переместились, ручки видны у пункта списка; на scroll-return.png вернулись. Title/bodyheading не пересекались в изученных кадрах.
- set_window_frame1000→1740: оба effect=confirmed, ширина действительно изменилась. В narrow.png и wide-return.png title/bodyheading раздельны; вертикальные полосы букв остались530…559 и597…614 points.
- Возврат через другую страницу **не выполнен**: row AX-локатор не нашёл AXCell, StopIteration. Изменение no-cover→cover на уже открытой странице и редактирование ещё не проверены. Не объявлять эти сценарии пройденными.

Артефакты: `/tmp/hover-exact.log`, `/tmp/hover-exact-artifacts/{actions.jsonl,initial-window.png,heading-0.png,heading-5.png,heading-11.png,scroll.png,scroll-return.png,narrow.png,wide-return.png}`, `/tmp/hover-unlocked-artifacts/`. Все снимки изучены. GUI освобождён и передан US3; новых серий при отсутствии лицензии не поставлено.

### Проверка исходника после снимка Юрия

- `PageHeaderView.titleTop`:40 с cover/noicon,32 безcover/noicon. `height(forWidth:)` включает высоту title и gap20. `PageTextView.textContainerOrigin.y` равен header.frame.maxY. Готовое состояние выше согласуется с этими формулами.
- `setCover` синхронно меняет coverSlot/header.hasCover и зовёт layoutColumn; последний выставляет header.frame, textContainerInset, invalidateTextContainerOrigin и updateEmptyParagraphHint. Отдельная needsLayout/viewport invalidation при смене только начала контейнера не задана (в отличие от applyLayout). Это **кандидат для проверки динамического добавления**, не установленная причина.
- Серая строка у Юрия может быть не дублированным title, а empty-heading placeholder: persistentPlaceholder рисуется в BlockLayoutFragment через Palette.textSecondary; при фокусе отдельный emptyParagraphHint NSTextField той же окраски ставится через markerLine+textContainerOrigin-baseline. Текущие live fixtures с непустым heading этот путь не покрыли. После лицензии требуется пустой heading с разными режимами фокуса и различимые контрольные title/body строки, проверка их границ между собой и изменение noicon/no-cover→cover в уже открытом окне.
- Удалять ensureLayout или менять origin/viewport без подтверждения причины не стали. Production исходники редактора остаются без правок; hover и overlap открыты.


## Подготовленный regression для пустого heading (ещё не запускался)

`EmptyHeadingCoverRegressionTests.swift`: различимое page-title «Название страницы», ПУСТОЙ heading2 (серая подсказка «Заголовок 2»), no icon. Два пути: cover до первого снимка и cover после отрисовки открытой страницы. В каждом состоянии focus title→empty body→away проверяет оба источника подсказки. Есть scroll/scroll-return, widths1740→1000→1740 и fresh editor того же сохранённого документа. Последнее — unit-модель переоткрытия, не живой переход дерева/вкладок.

Кадр снимается ДО диагностического markerLine/ensureLayout, чтобы само измерение не исправило потенциальный сбой. Проверяются: реальная строка первого блока ниже title+gap20; frame/нарисованные буквы focused hint не пересекают title и лежат на baseline/в полосе блока; при уходе фокуса NSTextField скрыт и серая persistent placeholder присутствует на строке блока.

Тест **не компилировался и не выполнялся** из-за Xcode license blocker; red→green не получен. Он не доказывает существование или устранение бага. После снятия blocker запускать на iMac через `imac-run --no-fallback --wait 1800`, jobs4, filter EmptyHeadingCoverRegressionTests, без GUI для невидимого unit. Затем отдельный реальный UI-проход пустого heading, переключений фокуса и noicon/no-cover→cover в существующем окне с возвратом через дерево/вкладки. Production fix остаётся отдельным от harness.

Source-цепочки уточнены: focused hint использует firstRect (screen→window→textView) лишь как fallback/горизонтальную поправку; основной baseline берётся из markerLine+textContainerOrigin, затем вычитается firstBaselineOffsetFromTop. Persistent hint рисуется в CGContext фрагмента через blockLine(layoutFragmentFrame+typographicBounds+glyphOrigin) и offset(drawPoint-layoutFragmentFrame). При смене emptyHintBlockID вызывается invalidateRenderingAttributes для старого/нового блока. Возможные разногласия этих двух путей при viewport/inset/focus ещё не наблюдены; правки по гипотезе не делались.


## Подтверждённое исправление setCover после снятия лицензии

Основа common `dc5235f`, merge в рабочую ветку `9a5789e`. Сборки и тесты только на iMac, очередь no-fallback, wait1800, jobs4.

- `EmptyHeadingCoverRegressionTests` впервые скомпилирован. Исходный production: **RED, 2 issues** (dynamic cover, persistent placeholder, focus title/away). Геометрия title и блока обновилась, но в ожидаемой серой строке оказались чёрные буквы. `/tmp/empty-heading-baseline.log`, повтор с PNG `/tmp/empty-heading-diagnostic.log`.
- RED PNG `/tmp/empty-heading-before.png` (`/tmp/empty-cover-unit/добавление к открытой странице-title.png`) показывает реальные «Контрольные абзацы» поверх «Название страницы». Это не ошибочная цветовая проверка: уже нарисованные TextKit2 фрагменты остались на прежних координатах после добавления cover. `invalidateTextContainerOrigin` обновлял геометрию, но не запрашивал новую раскладку этих видов.
- Scoped production fix `3d881a9`: только `PageTextView.setCover`. Если его вызов сдвинул textContainerOrigin.y, выставляются needsLayout и needsDisplay. Общий layoutColumn и mouseMoved не меняются. Координатор интегрировал как `386aaf5`; regression8dc084f интегрирован как `53a7712`.
- Тот же regression **GREEN** без ослабления assertions: первоначальный вариант8.074s; итоговый тест с сохранением GREEN PNG **1 test / 2 cases PASS8.176s**, `/tmp/empty-heading-final.log`. GREEN PNG `/tmp/empty-heading-after.png` (`/tmp/empty-heading-green/добавление к открытой странице-title.png`).
- Проверка соседей: **36/37 tests PASS**, 10 suites,22.774s. `/tmp/empty-heading-scoped-check.log`. Единственный сбой PageScrollPlaceTests: после роста attachment над якорем blockId меняется, offset7→22. Контроль на НЕИЗМЕНЁННОМ production baseline повторил тот же сбой (6 tests,1 failed,2 issues): `/tmp/empty-heading-scroll-control.log`. Это отдельный старый дефект; по указанию координатора здесь не исправлялся.
- Свежая Debug-сборка исправленного приложения на Xcode27.1 **build.exit=0**. Локальный `/tmp/empty-heading-build.exit`; iMac `build/empty-heading-review/{build.exit,build.log}` внутри runner worktree. Никаких старых binary за успешную свежую сборку не выдавали.

### Живое подтверждение пока заблокировано повторным lock

Единственный поставленный GUI-проход остановлен read-only preflight до сборки/запуска: `CGSSessionScreenIsLocked=Yes`, `kCGSSessionSecureInputPID=650`. Сохранены `/tmp/empty-heading-preflight.png` (полностью чёрный), `/tmp/empty-heading-session.txt`; оригиналы iMac `~/work/shots/empty-heading-current/{preflight.png,session.txt,actions.jsonl}`. Guard возвратил78. Состояние сеанса НЕ меняли, кликов вслепую не делали, GUI освобождён и напрямую передан US3 (тот предупреждён о блокировке). Свежую build затем выполнили без GUI.

После сообщения координатора об unlock остаётся один живой проход на свежем app: пустой heading2/noicon; различимые title/placeholder; persistent↔focused hint; add-cover к уже открытой странице; scroll/return, resize, реальные hover-движения и ручки. Unit red→green доказывает исправление найденного setCover overlay, но НЕ завершает живую приёмку и не устанавливает причину первоначального hover flicker. Hover остаётся отдельным незакрытым наблюдением.
