# MyNotion

Личное приложение заметок для macOS и iPhone: дерево страниц, блоки текста, автосохранение, синхронизация между Mac и iPhone.
План версии для iPhone — [specs/007-iphone-app/plan-draft.md](specs/007-iphone-app/plan-draft.md).
Требования, план и задачи — в [specs/001-core-pages-editor/](specs/001-core-pages-editor/) (страницы и текст) и
[specs/002-rich-blocks-text/](specs/002-rich-blocks-text/) (богатые блоки: переключатели, выноски, код, формулы,
картинки и файлы, видео, закладки, таблицы, колонки, цвета, упоминания, даты и напоминания),
[specs/003-pages-navigation/](specs/003-pages-navigation/) (обложки и вид страницы, избранное и недавние, вкладки и
«назад/вперёд», дублирование и «Переместить в», обратные ссылки, история версий, шаблоны).
Правила проекта — в [.specify/memory/constitution.md](.specify/memory/constitution.md).

## Что нужно

- Mac на Apple Silicon, macOS 26 или новее.
- Xcode 26, XcodeGen (`brew install xcodegen`).
- Для сервера синхронизации — Node.js 22 и pnpm.

## Сборка и запуск

Проект Xcode не хранится в репозитории: он создаётся из `project.yml`.

```sh
xcodegen generate
xcodebuild build -scheme MyNotion -destination 'platform=macOS,arch=arm64'
```

### iPhone

Цель `MyNotionPhone` (папка `PhoneApp/`, iOS 26+, только iPhone) собирается из того же `project.yml`. Под iPhone
собираются модули данных пакета, оболочка `PhoneShell` и редактор страницы `PhonePageEditor`; насквозь AppKit-модули
(редактор Mac, дерево, сетка баз) — только для Mac.

```sh
xcodegen generate
xcodebuild build -scheme MyNotionPhone -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/iphone
xcrun simctl boot 'iPhone 17 Pro'; open -a Simulator
xcrun simctl install booted build/iphone/Build/Products/Debug-iphonesimulator/MyNotion.app
xcrun simctl launch booted cloud.kurilov.mynotion.ios
```

На iMac: `scripts/imac/iphone-build.zsh` собирает модули и приложение под симулятор и устройство и прогоняет
`NotesCoreTests`, `SyncTests`, `PhoneShellTests` и `PhonePageEditorTests` в iPhone 17 Pro (iOS 26.5); `scripts/imac/iphone-sim-shot.zsh` запускает
приложение и снимает экран, `scripts/imac/iphone-shots.zsh` — снимки основных экранов в `build/iphone-shots/`.

```sh
imac-run --no-fallback --no-setup --fetch build/iphone-shots -- 'zsh scripts/imac/iphone-build.zsh && zsh scripts/imac/iphone-shots.zsh'
```

Живая проверка синхронизации «Mac + iPhone в симуляторе» на локальном сервере (боевой не трогается):
`scripts/imac/iphone-sync-live-check.zsh` — Mac выдаёт код, iPhone подключается, страница с Mac приходит на iPhone,
текст, напечатанный в редакторе iPhone, приходит на Mac, а блок, вставленный на Mac, появляется на открытой странице iPhone.
Затем тихий пуш: iPhone уходит в фон, Mac вставляет ещё блок, сервер шлёт пуш в подменный APNs
(`scripts/imac/apns-relay.mjs` отдаёт его в симулятор через `xcrun simctl push`); открытый iPhone забирает блок, лишних
пушей нет. Будить приложение тихим пушем симулятор не умеет («only supported on-device»): это проверяется на iPhone.
Снимки — дерево, страница с клавиатурой и в тёмной теме. Перед ней в копии на iMac должна лежать сборка `iphone-build.zsh`.

Флаги запуска iPhone (для снимков и проверок, `xcrun simctl launch … <флаги>`): `--database <путь>`, `--sample-pages`,
`--screen connect|settings|page:<название>`, `--sync-server`, `--sync-device-name`, `--sync-join-code-file`, `--sync-log`,
`--live-check-page`, `--live-check-edit`, `--live-check-mac-edit`. Работают только в отладочной сборке: сборка для
TestFlight их не принимает.

**TestFlight.** `ITSAppUsesNonExemptEncryption = NO` уже в `PhoneApp/Info.plist`: вопроса о шифровании не будет. Иконка —
та же, что у Mac (`PhoneApp/Resources/Assets.xcassets`). Номер сборки (`CURRENT_PROJECT_VERSION`) у каждой выкладки
должен расти; руками его не поднимать — скрипт подставляет время сборки. Выкладка одной командой с основного Mac:

```sh
zsh scripts/iphone-testflight.zsh   # TESTFLIGHT_ARCHIVE_ONLY=1 — только проверить подпись
```

Сборка идёт на iMac. Ключ App Store Connect (`~/.codex/secrets/asc-api-DC5QSJ54MB.*`) уходит туда только на время
прогона. Подпись Release — вручную: сертификат Apple Distribution в отдельной связке `~/.config/mynotion-release/` на
iMac (пароль рядом, права 600) и профиль «MyNotion iPhone App Store». Тестеры — внутренняя группа TestFlight «Юрий».

Версию для людей (`MARKETING_VERSION` в `project.yml`, сейчас 0.1.0) поднимать только к новому выпуску.

## Модули

Код приложения — в пакете `Packages/MyNotionKit`, у каждого модуля свои тесты в `Tests/<Модуль>Tests`.

| Модуль | Что делает |
|--------|------------|
| `NotesCore` | модель страниц, блоков и баз, база SQLite (схема v9), запись правок, копия ветки, перенос блоков, шаблоны, эталонные базы для замеров |
| `PageEditor` | редактор страницы; каждый тип блока — свой описатель в `BlockKinds/` (меню «/», вид, клавиши, образцы галереи, часть «богатой» страницы) |
| `PageTree`, `PageSearch` | дерево страниц в боковой панели, поиск по всем страницам |
| `VisualStyle` | цвета, шрифты и размеры под Notion, светлая и тёмная тема |
| `CodeHighlighting` | подсветка блоков кода по строкам |
| `MathRendering` | формулы LaTeX (SwiftMath, шрифт Latin Modern Math) |
| `Attachments` | копии картинок и файлов на Mac, отправка на сервер частями с шифрованием, уборка ненужных |
| `EmbeddedMedia` | видеофайлы и ролики YouTube и Vimeo на странице |
| `LinkPreview` | данные карточки закладки: заголовок, описание, картинка и значок сайта |
| `Reminders` | даты в тексте и уведомления напоминаний |
| `EmojiPicker` | окно выбора эмодзи для иконок страниц и выносок |
| `Sync` | зашифрованные пачки правок между Mac через сервер |
| `PhoneShell` | логика оболочки iPhone без UIKit: подключение кодом с Mac, синхронизация на переднем плане и досылка в фоне, круг по тихому пушу и токен пушей, дерево страниц |
| `PhonePageEditor` | редактор страницы на iPhone (UIKit): блок — ячейка списка со своим текстом |
| `MarkdownExport`, `NotionImport` | выгрузка в Markdown и импорт выгрузки Notion или своей выгрузки |
| `Navigation` | вкладки окна, «назад/вперёд» с местом прокрутки, закрытые вкладки |
| `PageCover` | обложка страницы: галерея «Цвета и градиенты», своя картинка, сдвиг |
| `PagePicker` | окно выбора страницы для «Переместить в» (⇧⌘P) |
| `Backlinks` | индекс обратных ссылок `page_link`, строка «↗ N обратных ссылок» и её список |
| `PageVersions` | история версий: снимки, прореживание, разница, восстановление с ⌘Z |
| `UIGallery`, `ServiceLaunch` | галерея снимков интерфейса и служебные режимы запуска без фокуса |
| `Databases` | базы 004: модели значений 18 типов, запрос вида, индексатор ячеек, операции с отменой, фоновый пересчёт формул |
| `Formulas` | язык формул: разбор, вычисление, функции по разделам |
| `DatabaseGrid`, `DatabaseViewBar`, `DatabaseRowPage` | сетка таблицы, строка вида, страница строки; реестры пунктов меню и окон |
| `NotionSchemaFetch` | схема баз из Notion по ключу (Q3) |
| `ControlProtocol`, `ControlClient` | команда `mynotion`: каталог команд, разбор аргументов, формат ответа и ошибок; клиент (запускает приложение, если оно закрыто) |
| `ControlServer`, `ControlCommands` | вход для команд в приложении: сокет, исполнитель с одним шагом отмены на команду, обработчики страниц, блоков, баз, окон, библиотеки, импорта и выгрузки, журнал |
| `PageMarkdown` | Markdown ↔ блоки страницы для `page read`, `page write` и `page create --markdown`; чего в MyNotion нет, переносится текстом с предупреждением |

### Вкладки и меню «История»

Каждое окно держит свои вкладки; у вкладки — своя история переходов и место прокрутки. Вкладки и их история
сохраняются в базе и возвращаются после перезапуска.

| Команда | Клавиши | Где |
|---------|---------|-----|
| Новая вкладка (окно «Open in new tab…» с недавними) | ⌘T | «Файл», «+» на полосе вкладок |
| Открыть закрытую вкладку | ⇧⌘T | «Файл» |
| Закрыть вкладку | ⌘W | «Файл», «×» на вкладке |
| Назад / Вперёд | ⌘[ / ⌘] | меню «История», «‹ ›» на полосе вкладок |
| Следующая / предыдущая вкладка | ⌃⇥ / ⌃⇧⇥ | «Окно» |
| Открыть в новой вкладке | ⌘-щелчок | строка панели, ссылка на странице |

## Тесты

```sh
# Всё — на iMac через imac-run (см. «Проверки на iMac»): основной Mac только правит код.
# Модули (Swift Testing)
cd Packages/MyNotionKit && imac-run --no-fallback --wait 1800 --no-setup -- swift test --jobs 4

# Сценарии XCUITest — сборка и прогон на iMac, журнал и снимки возвращаются сюда
scripts/imac/run-on-imac.sh uitest [-only-testing:UITests/<Класс>]

# Замеры бюджета (quickstart.md 002) — сборка Release, схема MyNotionPerformance.
# PerformanceTests запускает приложение через систему, как Dock; PerformanceUITests — замеры через XCUITest.
scripts/imac/run-on-imac.sh uitest --release [-only-testing:PerformanceTests/<Класс>]

# Сервер
cd server && imac-run --setup 'pnpm install --frozen-lockfile' -- pnpm test
```

## Флаги запуска

| Флаг | Что делает |
|------|------------|
| `--database <путь>` | открыть базу из указанного файла вместо `~/Library/Application Support/MyNotion/MyNotion.sqlite` |
| `--generate-reference-library <путь>` | создать эталонную базу (1 000 страниц, 100 000 блоков) и выйти |
| `--generate-visual-sample` | добавить в открытую базу страницу «MyNotion — образец» для сверки с Notion и открыть её |
| `--generate-rich-sample` | добавить в открытую базу «богатую» страницу на 1 000 блоков (замеры 002, quickstart.md) и открыть её; части блоков дают описатели типов |
| `--launch-report <путь>` | записать в файл время запуска и память в покое (для замеров) |
| `--window-snapshot <путь>` | когда страница готова, снять окно в PNG и выйти (работает и при заблокированном экране) |
| `--ui-gallery <папка>` | на своей временной базе снять все состояния интерфейса (светлая и тёмная тема, 1440×900, ключевые ещё 900×700), положить рядом `index.html` и `manifest.json` и выйти |
| `--ui-gallery-only <часть имени>` | вместе с `--ui-gallery`: снять только состояния, в имени которых есть эта строка |
| `--generate-003-sample` | добавить в открытую базу образец 003: обложки, избранное, шаблоны, ветку для дублирования, страницы обратных ссылок |
| `--generate-versions-sample` | только страница «Замер: история версий» с 200 версиями (UI-тест истории) |
| `--versions-quick` | версии пишутся через 1 с тишины, не чаще раза в 2 с — UI-тест истории без минутных ожиданий |
| `--tabs-benchmark <путь>` | замер вкладок: переключение, «назад», «вперёд», место прокрутки, память 20 вкладок; отчёт в файл и выход |
| `--rich-memory-check <путь>` | память за 120 переходов между «богатыми» страницами; отчёт в файл и выход |
| `--backlink-benchmark <путь>` | первое заполнение индекса обратных ссылок на эталоне; отчёт в файл и выход |
| `--appearance light\|dark` | светлая или тёмная тема вместо системной |
| `--search-benchmark <путь>` | замер поиска (T054, SC-009): слова печатаются в поле поиска по букве, время от нажатия до выдачи на экране; отчёт с p95 в файл и выход |
| `--typing-benchmark <путь>` | замер отклика: 200 нажатий в странице на 1 000 блоков, переходы между страницами, набор и прокрутка страницы на 10 000 блоков; отчёт с p95 в файл и выход |
| `--sync-server <адрес>`, `--sync-device-name <имя>` | живая проверка синхронизации: адрес сервера и имя Mac без окна настроек |
| `--sync-connect-token-file <путь>` | подключить как первый Mac токеном из файла (файл стирается) |
| `--sync-write-join-code <путь>` | после подключения записать код для второго Mac в файл |
| `--sync-log <путь>` | вместе с флагами выше: писать ход синхронизации в файл |
| `--sync-join-code-file <путь>` | подключить кодом из файла (ждёт, пока файл появится); вместе — `scripts/imac/sync-live-check.sh` |
| `--export-markdown <папка>` | выгрузить все записи в Markdown в `<папка>/MyNotion-выгрузка-<дата>/` без окна выбора папки, напечатать путь и выйти (код 0 — готово, 1 — ошибка, частичной папки не остаётся) |
| `--import-notion <путь>` | импортировать выгрузку Notion (ZIP «Export → Markdown & CSV» или распакованную папку) в ветку «Импорт из Notion — <дата>» без окна выбора, напечатать отчёт и выйти (код 0 — готово, 1 — ошибка, ветка откачена, 2 — эта выгрузка уже импортирована, повтор не начат) |

**Служебные режимы не берут фокус.** Галерея, снимки окна, замеры и эталонная база (`--ui-gallery`, `--ui-gallery-only`, `--window-snapshot`, `--hover-sidebar-row`, `--generate-reference-library`, `--launch-report`, `--typing-benchmark`, `--search-benchmark`, `--export-markdown`, `--import-notion`, а также `--generate-visual-sample` и `--generate-rich-sample` вместе с ними) идут, пока человек работает в других программах. Приложение не становится активным, не стоит в Dock, его окна лежат под всеми окнами. Нигде в этих режимах нет `activate`, `makeKeyAndOrderFront` и `orderFrontRegardless`. Новый служебный флаг обязан работать так же: он добавляется в `LaunchPresence.serviceFlags` (модуль `ServiceLaunch`) и в его тест. Запуск без служебных флагов — обычное приложение.

## Команда mynotion для агентов

Приложение слушает сокет и отвечает на команды `mynotion`: страницы и блоки, базы, поиск, избранное, история версий, окна, импорт и выгрузка. Каждый ответ — одна строка JSON (`{"ok":true,"data":…}` или `{"ok":false,"error":{…}}`). Каталог команд — `mynotion commands --json`; весь охват окна — `specs/005-cli-control/contracts/coverage.md` (его сверяет тест `CoverageTableTests`).

**Установка.** `scripts/install-cli.sh` собирает Release на iMac, кладёт `MyNotion.app` в `/Applications`, ссылку `~/.local/bin/mynotion` на `MyNotion.app/Contents/Helpers/mynotion` и скилл `mynotion` в `~/.agents/skills`. `--target <папка>` — другое место приложения (на iMac: `~/Applications`), `--app <MyNotion.app>` — готовая сборка, `--skip-app` — только ссылка и скилл. Запущенное приложение скрипт не заменяет. Клиент находит своё приложение по ссылке, поэтому после переустановки ничего настраивать не нужно.

**Сокет.** `~/Library/Application Support/MyNotion/control.sock`, права `0600`: команды видны только владельцу. Для другой базы (`--database <путь>`) сокет лежит рядом с ней; если путь длиннее 100 байт, он ложится в `$TMPDIR` по хэшу папки базы. Клиенту другой сокет задают `--socket <путь>` или `MYNOTION_SOCKET`. Закрытое приложение клиент запускает сам, в фоне и без фокуса (`--no-launch` отключает запуск, тогда ответ — `app_not_running`, код выхода 5).

**Журнал.** Одна строка на команду в журнале системы: имя, указатель страницы или блока, итог или код ошибки, длительность, имя агента (`--agent` или `MYNOTION_AGENT`). Текста записей в нём нет. Читать: `log show --predicate 'category == "control"'`. Имя агента попадает и в историю версий страницы («Откатить правку агента» — `mynotion history restore`).

**Тесты и проверки.** Тесты модулей `Control*` и `PageMarkdown` — как остальные (`swift test --filter …` на iMac). Сквозной сценарий — `scripts/imac/cli-e2e.zsh`, живые проверки групп — `scripts/imac/cli-live-check.zsh`, замеры ответа — `scripts/imac/cli-bench.zsh` (все через `scripts/imac/run-on-imac.sh lock --`).

## Сервер синхронизации и файлов

Сервер в `server/` — почтовый ящик зашифрованных пачек правок и частей файлов: содержимого заметок и файлов он не видит.
API — в [contracts/sync-and-files-api.md](specs/002-rich-blocks-text/contracts/sync-and-files-api.md).

```sh
cd server && pnpm install && pnpm test
pnpm build && pnpm start   # http://localhost:3000/health → {"status":"ok"}
```

Настройки — переменными окружения: `PORT` (3000), `DATA_DIR` (`./data`: база, резервные копии, файлы в `files/`),
`BACKUP_KEEP` (14 копий), `FILES_LIMIT_GB` (50 ГБ на файлы), `SHARES_LIMIT_GB` (10 ГБ на страницы по ссылке).
Развёртывание — `server/Dockerfile` и `docker-compose.yml`.

**Тихие пуши iPhone (1П).** Пришла пачка с Mac — сервер будит iPhone тихим пушем Apple, iPhone забирает её сам
(в пуше ничего из записей нет). Нужен ключ APNs команды `DC5QSJ54MB` (файл `.p8` из developer.apple.com → Keys):

- положить ключ на сервер в том данных: `data/apns/AuthKey_<KEY_ID>.p8`, права `600`;
- в `.env` рядом с `docker-compose.yml`: `APNS_KEY_FILE=/data/apns/AuthKey_<KEY_ID>.p8` и `APNS_KEY_ID=<KEY_ID>`;
- необязательно: `APNS_TEAM_ID` (`DC5QSJ54MB`), `APNS_TOPIC` (`cloud.kurilov.mynotion.ios`),
  `PUSH_MIN_INTERVAL_SECONDS` (300 — не чаще одного пуша устройству).

Без ключа сервер пишет в журнал «Пуши iPhone выключены» и работает как прежде. Токены iPhone приходят через
`PUT /devices/me/push-token` (контракт — в [sync-api.md](specs/001-core-pages-editor/contracts/sync-api.md)).
Приложение, которое смахнули из переключателя программ, iOS тихими пушами не будит: правки придут при открытии.

**Страницы по ссылке (006).** «•••» → «Поделиться» или `mynotion page share on <стр>`: Mac кладёт на сервер открытую
копию страницы (снимок без закрытого), сервер показывает её по адресу `/s/<ссылка>` любому браузеру без входа.
API и граница снимка — в [contracts/share-api.md](specs/006-share-link/contracts/share-api.md). Браузерные проверки:
`cd server && pnpm build && pnpm exec playwright test` (снимки экрана — в `server/e2e-results/screenshots/`).

Что остаётся после выключения ссылки. Снимок — открытый текст, поэтому сервер стирает его по-настоящему: SQLite
затирает освобождённое нулями (`secure_delete`), журнал WAL сразу переносится и обрезается, файлы ссылки удаляются.
Ежедневные копии базы снимков не содержат (в копии только сами ссылки, без содержимого; после восстановления Mac
выложит снимки заново), файлы ссылок в копии не входят. Но на диске сервера и в его снимках у хостинга стёртое
может пожить до перезаписи — это уровень диска, не приложения. Пока Mac выключен или без сети, сервер не узнает,
что страницу убрали в корзину или вынесли из ветки: закрытие уйдёт, как только Mac выйдет на связь (повтор
через 15 с, 30 с, минуту… и сверка раз в 5 минут); мгновенно закрыть — выключить ссылку с любого Mac или из `mynotion`.

## Проверки на iMac

На основном Mac приложение не запускается ни в каком виде и ничего не собирается — только правка кода и git. Сборки, тесты, галерея и живые проверки — на iMac Юрия через `imac-run` (skill `imac`): очередь сама делит iMac между агентами, всё с окнами берёт место «экран» и на основной Mac не переносится никогда.

```sh
scripts/imac/run-on-imac.sh gallery [--release] [--only <слово>] [--out <папка>]   # галерея, снимки — сюда
scripts/imac/run-on-imac.sh run [--release] <флаги приложения>                      # любой служебный режим
scripts/imac/run-on-imac.sh uitest [--release] [-only-testing:…] [--out <папка>]     # UI-тесты и замеры Xcode
scripts/imac/run-on-imac.sh lock -- <команда>    # своя серия шагов в копии проекта на iMac, «экран» занят
scripts/imac/run-on-imac.sh ssh <команда>        # быстрая команда на iMac в копии проекта, без очереди
scripts/imac/run-on-imac.sh status               # очередь, macOS, Xcode, режим автоматизации
scripts/imac/sync-live-check.sh [--out <папка>]  # два Mac вживую (US5)
scripts/imac/sync-memory-check.sh                # память в покое с синхронизацией (T095)
```

Сборка идёт на iMac не больше чем в 4 потока, папки сборки — `build/imac-*` в копии проекта (кэш между прогонами). Место «экран» ждём до 30 минут (`MYNOTION_IMAC_WAIT`). Экран iMac уже ретина, окно 1440×900 влезает, режим экрана не меняется.

### Что включить на iMac один раз

Нужен пароль Юрия (`sudo`): через «Общий экран» (`open vnc://iMac-Yury.local`).

1. macOS 26+ и Xcode 26+; `sudo xcode-select -s /Applications/Xcode.app`, `sudo xcodebuild -license accept`, `xcodebuild -runFirstLaunch`.
2. xcodegen в `~/.local/bin` (без Homebrew): скачать `xcodegen.zip` со страницы выпусков github.com/yonaskolb/XcodeGen и распаковать `bin/xcodegen` и `share/xcodegen` в `~/.local`.
3. Режим разработчика: `sudo DevToolsSecurity -enable`.
4. UI-тесты без окна пароля: `sudo automationmodetool enable-automationmode-without-authentication`.
5. Первый `uitest` — смотреть экран: если macOS спросит, разрешить «UITests-Runner» / Xcode управлять компьютером («Универсальный доступ»), разрешить.

Пузырёк раскладки под курсором (у iMac несколько раскладок) XCUITest принимает за чужой диалог — `uitest` и `sync-live-check` выключают его сами (`TSMLanguageIndicatorEnabled`, без sudo).

Проверка: `scripts/imac/run-on-imac.sh status`. Чего не хватает, сценарии говорят сами — понятным сообщением до сборки. Если UI-тесты из SSH всё равно не идут, запасной прогон через Терминал iMac: `MYNOTION_UITEST_VIA_TERMINAL=1` перед командой (`lock -- 'MYNOTION_UITEST_VIA_TERMINAL=1 zsh scripts/imac/on-imac.sh uitest …'`).

### Запасной путь: виртуальный Mac

Только если iMac недоступен: `scripts/vm/run-in-vm.sh` с теми же режимами (gallery, run, uitest, lock, ssh, status), `scripts/vm/sync-live-check.sh`, `scripts/vm/sync-memory-check.sh`. Виртуальный Mac на 8 ГБ перегружает основной Mac, поэтому после проверки он выключается сам (`MYNOTION_VM_KEEP=1` — оставить на серию, потом `lume stop cua-base-3416f98dedcf`). Его экран — 1512×982 точек с ретиной, `gallery` включает режим программой `scripts/vm/displaymode.swift`.
