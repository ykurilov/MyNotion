# Общее для сценариев, которые выполняются НА iMac (внутри `imac-run`, в копии проекта).
# Подключается через `source`. Папки сборки — в build/ копии проекта: build/ в .gitignore,
# поэтому `imac-run` её не стирает и следующая сборка идёт с кэшем.

# Одна задача на iMac — не больше 4 потоков (8 ядер на 2 тяжёлых места).
JOBS=4
WORK=$PWD

fail() { print -u2 -- "[MyNotion/iMac] $*"; exit 3; }

# Постоянная подпись Release (project.yml) — сертификатом Developer ID основного Mac. На iMac его нет:
# здесь сборки подписываются ad-hoc, а приложение для установки переподписывает scripts/sign-app.sh.
if ! security find-identity -p codesigning -v 2>/dev/null | grep -q '"Developer ID Application:'; then
  export XCODE_XCCONFIG_FILE=$WORK/scripts/imac/adhoc-signing.xcconfig
fi

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
# Погасший экран блокирует сеанс: окна не видны, AppKit их не рисует, и замеры памяти и времени выходят не о
# приложении (T085: куча вкладок 95 → 190 МБ вместо 33 → 36). Экран будится; не проснулся — прогон не идёт.
require_gui_session() {
  [[ $(stat -f %Su /dev/console) == $USER ]] || fail "На iMac не открыт сеанс пользователя $USER: окнам негде появиться."
  local tries
  for tries in 1 2 3 4 5; do
    screen_is_locked || return 0
    caffeinate -u -t 2
  done
  fail "Экран iMac заблокирован и не проснулся: окна не видны, замеры недействительны."
}

screen_is_locked() {
  ioreg -n Root -d1 | grep -q '"CGSSessionScreenIsLocked"=Yes'
}

# XCUITest без окна пароля: режим разработчика и режим автоматизации без подтверждения.
# Включается один раз через sudo (README → «Что включить на iMac один раз»).
require_ui_automation() {
  DevToolsSecurity -status 2>/dev/null | grep -q 'enabled' \
    || fail "На iMac выключен режим разработчика: нужно один раз 'sudo DevToolsSecurity -enable'."
  automationmodetool 2>/dev/null | grep -qi 'does not require' \
    || fail "На iMac режим автоматизации UI просит пароль: нужно один раз 'sudo automationmodetool enable-automationmode-without-authentication'."
  # У iMac несколько раскладок: macOS показывает под курсором пузырёк раскладки, XCUITest принимает его
  # за чужой диалог и не может щёлкнуть в поле. Подсказка выключается (только у пользователя, без sudo).
  [[ $(defaults read kCFPreferencesAnyApplication TSMLanguageIndicatorEnabled 2>/dev/null) == 0 ]] \
    || defaults write kCFPreferencesAnyApplication TSMLanguageIndicatorEnabled -bool false
}

# Сборка приложения: build_app <Debug|Release> <папка сборки>; путь к .app — в APP.
build_app() {
  local config=$1 dd=$2
  # errexit не действует внутри функции, если вызывающий код проверяет её через if/||.
  # Сбрасываем прежний путь и явно возвращаем ошибку каждой стадии до присваивания APP.
  unset APP
  xcodegen generate -q || return $?
  xcodebuild -scheme MyNotion -configuration $config -derivedDataPath $dd -jobs $JOBS build -quiet || return $?
  APP=$WORK/$dd/Build/Products/$config/MyNotion.app
}

# Чужие системные процессы не завершаем: перекрывающий диалог остаётся в артефактах UI-теста.
close_stale_prompts() {
  if pgrep -x SecurityAgent >/dev/null 2>&1; then
    print -u2 -- "[MyNotion/iMac] SecurityAgent активен; системный запрос может перекрывать UI. Процесс оставлен без изменений."
  fi
}

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

# Замер — только на тихой машине: свежая сборка будит Spotlight (mds_stores до 130 % CPU на минуту-две), и
# цифры замера под ним — шум (T085). Ждём, пока индексатор не уймётся (не дольше 5 мин), и пишем, сколько ждали.
wait_for_quiet_indexer() {
  local busy waited=0
  while (( waited < 300 )); do
    busy=$(ps -axo pcpu=,comm= | awk '/mds_stores|\/mds$|fseventsd/ { s += $1 } END { printf "%d", s }')
    (( busy < 15 )) && break
    sleep 5; (( waited += 5 ))
  done
  print -- "[MyNotion/iMac] индексатор: ждали ${waited} с, нагрузка ${busy} % CPU; $(uptime | sed 's/.*load/load/')"
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

# Симулятор iPhone 17 Pro на iOS 26.5 для MyNotionPhone: загрузить и поставить сборку scripts/imac/iphone-build.zsh.
# UDID — в DEVICE, путь к приложению — в PHONE_APP.
boot_iphone_simulator() {
  PHONE_APP=$WORK/build/iphone/Build/Products/Debug-iphonesimulator/MyNotion.app
  [[ -d $PHONE_APP ]] || fail "Нет сборки $PHONE_APP: сначала scripts/imac/iphone-build.zsh"
  DEVICE=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if runtime.endswith("iOS-26-5"):
        print(next(d["udid"] for d in devices if d["name"] == "iPhone 17 Pro")); break')
  [[ -n $DEVICE ]] || fail "Нет симулятора iPhone 17 Pro на iOS 26.5"
  xcrun simctl boot $DEVICE 2>/dev/null || true
  xcrun simctl bootstatus $DEVICE -b >/dev/null
  xcrun simctl status_bar $DEVICE override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
  xcrun simctl install $DEVICE $PHONE_APP
}
