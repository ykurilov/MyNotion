# Общее для сценариев, которые выполняются НА iMac (внутри `imac-run`, в копии проекта).
# Подключается через `source`. Папки сборки — в build/ копии проекта: build/ в .gitignore,
# поэтому `imac-run` её не стирает и следующая сборка идёт с кэшем.

# Одна задача на iMac — не больше 4 потоков (8 ядер на 2 тяжёлых места).
JOBS=4
WORK=$PWD

fail() { print -u2 -- "[MyNotion/iMac] $*"; exit 3; }

# macOS 26+ и Xcode 26+ (Swift 6.2), xcodegen — без них MyNotion не собрать.
require_toolchain() {
  local os xc
  os=$(sw_vers -productVersion)
  xc=$(xcodebuild -version 2>/dev/null | awk 'NR==1 {print $2}')
  (( ${os%%.*} >= 26 )) || fail "На iMac macOS $os, а MyNotion нужен macOS 26+. Сначала обновить iMac (README → «Проверки на iMac»)."
  [[ -n $xc ]] && (( ${xc%%.*} >= 26 )) || fail "На iMac Xcode ${xc:-не выбран}, нужен Xcode 26+ (xcode-select -s /Applications/Xcode.app)."
  command -v xcodegen >/dev/null || fail "На iMac нет xcodegen в ~/.local/bin (README → «Что включить на iMac один раз»)."
}

# Окна и `open` работают, только если на iMac кто-то вошёл в систему (там автовход).
require_gui_session() {
  [[ $(stat -f %Su /dev/console) == $USER ]] || fail "На iMac не открыт сеанс пользователя $USER: окнам негде появиться."
}

# XCUITest без окна пароля: режим разработчика и режим автоматизации без подтверждения.
# Включается один раз через sudo (README → «Что включить на iMac один раз»).
require_ui_automation() {
  DevToolsSecurity -status 2>/dev/null | grep -q 'enabled' \
    || fail "На iMac выключен режим разработчика: нужно один раз 'sudo DevToolsSecurity -enable'."
  automationmodetool 2>/dev/null | grep -qi 'does not require' \
    || fail "На iMac режим автоматизации UI просит пароль: нужно один раз 'sudo automationmodetool enable-automationmode-without-authentication'."
}

# Сборка приложения: build_app <Debug|Release> <папка сборки>; путь к .app — в APP.
build_app() {
  local config=$1 dd=$2
  xcodegen generate -q
  xcodebuild -scheme MyNotion -configuration $config -derivedDataPath $dd -jobs $JOBS build -quiet
  APP=$WORK/$dd/Build/Products/$config/MyNotion.app
}

# Системный запрос пароля к связке ключей (SecurityAgent) переживает приложение, которое его вызвало, и висит
# посреди экрана: следующий тест щёлкает в него вместо своей кнопки. SIGTERM он пропускает, поэтому -9.
close_stale_prompts() { pkill -9 -x SecurityAgent 2>/dev/null || true; }

# Секреты синхронизации тестовых экземпляров — из связки ключей: следующая сборка с другой подписью
# при встрече с ними вызвала бы запрос пароля.
forget_sync_secrets() {
  while security delete-generic-password -s cloud.kurilov.mynotion.sync >/dev/null 2>&1; do :; done
  close_stale_prompts
}

# Приложение — в сеансе пользователя через `open` (из SSH так можно); вывод — в консоль.
run_app() {
  local out=$WORK/build/imac-app
  mkdir -p $out; rm -f $out/stdout $out/stderr
  open -W -n $APP --stdout $out/stdout --stderr $out/stderr --args "$@"
  cat $out/stdout $out/stderr 2>/dev/null || true
}

# Прогон собранных UI-тестов: xctest_run <папка Products> <папка итогов> [аргументы xcodebuild...]
# Итоги: <папка итогов>/uitest.log, result.xcresult, вложения (снимки) в attachments/.
# MYNOTION_UITEST_VIA_TERMINAL=1 — запасной путь: прогон из Терминала в сеансе пользователя, как в виртуальном Mac.
xctest_run() {
  local products=$1 results=$WORK/$2; shift 2
  local run; run=$(cd $products && ls *.xctestrun | head -1)
  rm -rf $results; mkdir -p $results
  local cmd=(xcodebuild test-without-building -xctestrun $WORK/$products/$run -destination 'platform=macOS,arch=arm64'
             -parallel-testing-enabled NO -resultBundlePath $results/result.xcresult "$@")
  local rc=0
  if [[ ${MYNOTION_UITEST_VIA_TERMINAL:-} == 1 ]]; then
    print -r -- "#!/bin/zsh
${(q)cmd[@]} > ${(q)results}/uitest.log 2>&1
echo \$? > ${(q)results}/uitest.done
osascript -e 'tell application \"Terminal\" to quit' &" > $results/run.command
    chmod +x $results/run.command; open $results/run.command
    for _ in {1..720}; do [[ -f $results/uitest.done ]] && break; sleep 5; done
    rc=$(cat $results/uitest.done 2>/dev/null || echo 124)
  else
    $cmd > $results/uitest.log 2>&1 || rc=$?
  fi
  # Замеры печатают итоги строками «Запуск…», «Память…», «Набор…», «Поиск…», «Импорт…».
  grep -E 'Test Case .*(passed|failed|skipped)|error:|XCTAssert|Executed|TEST (EXECUTE )?(SUCCEEDED|FAILED)|Задержка|^(Запуск|Из них|Память|Набор|Переход|Открытие|Прокрутка|Поиск|Импорт|Снимок|Проба|Миграция|Индекс|Переключение|Назад|Место|Дублирование|Восстановление|История|Первое)' \
    $results/uitest.log | tail -60
  xcrun xcresulttool export attachments --path $results/result.xcresult --output-path $results/attachments >/dev/null 2>&1 \
    && (cd $results/attachments && python3 -c "import json,os;[os.rename(a['exportedFileName'],a['suggestedHumanReadableName']) for t in json.load(open('manifest.json')) for a in t['attachments']]" 2>/dev/null) || true
  # Пробы пишут снимки в ~/probe-shots — домашняя папка iMac не для этого, уносим к итогам.
  [[ -d ~/probe-shots ]] && mv ~/probe-shots $results/probe-shots
  print -- "exit=$rc"
  return $rc
}
