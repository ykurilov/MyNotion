#!/bin/zsh
# Живая проверка «Mac + iPhone в симуляторе» на iMac: локальный сервер из server/ со своей временной базой и портом,
# Mac-приложение подключается токеном bootstrap и выдаёт код, iPhone подключается кодом, получает страницу
# «MyNotion — образец» с Mac, открывает её и печатает текст в редакторе — текст должен прийти в базу Mac. Затем Mac
# командой `mynotion` вставляет блок под этим текстом — он должен появиться на открытой странице iPhone.
# Снимки: дерево, страница с клавиатурой, страница в тёмной теме. Боевой сервер не трогается.
#
#   scripts/imac/iphone-sync-live-check.zsh [--out <папка на этом Mac>]
# Нужна сборка iPhone в копии на iMac: сначала scripts/imac/iphone-build.zsh.
set -euo pipefail

REPO=${0:A:h:h:h}

if [[ ${MN_ON_IMAC:-} != 1 ]]; then
  OUT=/tmp/mn-phone-live-$(date +%H%M%S)
  while (( $# )); do case $1 in --out) OUT=$2; shift 2;; *) shift;; esac; done
  cd $REPO; stage=$(mktemp -d /tmp/mynotion-imac.XXXXXX); rc=0
  imac-run --gui --no-fallback --no-setup --wait ${MYNOTION_IMAC_WAIT:-1800} --fetch build/imac-phone-live --out $stage \
    -- "MN_ON_IMAC=1 zsh scripts/imac/iphone-sync-live-check.zsh" || rc=$?
  src=($stage/build/imac-phone-live(N/) $stage/**/build/imac-phone-live(N/D))
  if (( $#src )); then rm -rf $OUT; mkdir -p ${OUT:h}; mv $src[1] $OUT; print -- "Итог: $OUT"; fi
  rm -rf $stage; exit $rc
fi

# Дальше — на iMac, в копии проекта.
source ${0:A:h}/lib.sh
require_toolchain; require_gui_session

PORT=39124
LIVE=/tmp/mn-phone-live
RESULTS=$WORK/build/imac-phone-live
PAGE='MyNotion — образец'
EDIT="Правка с iPhone $(date +%H:%M:%S)"
MAC_EDIT="Правка с Mac $(date +%H:%M:%S)"
BUNDLE=cloud.kurilov.mynotion.ios

server_pid=""; mac_pid=""
cleanup() {
  cp $LIVE/phone.log $LIVE/mac.log $LIVE/server.log $RESULTS/ 2>/dev/null || true
  [[ -n $mac_pid ]] && kill $mac_pid 2>/dev/null || true
  [[ -n $server_pid ]] && kill $server_pid 2>/dev/null || true
  [[ -n ${DEVICE:-} ]] && { xcrun simctl terminate $DEVICE $BUNDLE 2>/dev/null; xcrun simctl keychain $DEVICE reset 2>/dev/null; } || true
  forget_sync_secrets
}
trap cleanup EXIT INT TERM HUP
rm -rf $LIVE $RESULTS; mkdir -p $LIVE $RESULTS

# wait_for <секунды> <описание> <команда…>: ждать, пока команда не выполнится успешно.
wait_for() {
  local seconds=$1 what=$2; shift 2
  local deadline=$(( SECONDS + seconds ))
  until "$@" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || { print -u2 -- "[MyNotion/iMac] не дождались: $what"; return 1; }
    sleep 0.5
  done
}

# 1. Сервер на iMac.
(cd server && pnpm install --frozen-lockfile --silent && pnpm --silent build)
# Свой сервер, оставшийся от оборванного прогона (запущен из этой же копии), — погасить; чужой не трогать.
for pid in $(lsof -tiTCP:$PORT -sTCP:LISTEN 2>/dev/null || true); do
  [[ $(ps -o command= -p $pid) == "node $WORK/server/dist/main.js" ]] && kill $pid && sleep 1
done
[[ -z $(lsof -tiTCP:$PORT -sTCP:LISTEN 2>/dev/null || true) ]] || fail "Порт $PORT занят: чужой сервер оставлен без изменений."
DATA_DIR=$LIVE/server PORT=$PORT node $WORK/server/dist/main.js > $LIVE/server.log 2>&1 &
server_pid=$!
wait_for 15 "сервер" curl -sf http://127.0.0.1:$PORT/health
(cd server && DATA_DIR=$LIVE/server node dist/cli.js bootstrap --name 'Mac A' --token-only > $LIVE/token)
started=$SECONDS

# 2. Mac: своя база с образцом, подключение токеном, код для iPhone — в файл.
build_app Debug build/imac-phone-live-mac
# Через `open`, как из Dock: запущенное прямо из сеанса SSH приложение не видит связку ключей пользователя.
open -n -a $APP --args --database $LIVE/mac.sqlite --generate-visual-sample --versions-quick \
  --sync-server http://127.0.0.1:$PORT --sync-device-name 'Mac A' --sync-connect-token-file $LIVE/token \
  --sync-write-join-code $LIVE/join-code --sync-log $LIVE/mac.log
wait_for 30 "Mac-приложение" pgrep -nf -- "--database $LIVE/mac.sqlite"
mac_pid=$(pgrep -nf -- "--database $LIVE/mac.sqlite")
wait_for 120 "код подключения с Mac" test -s $LIVE/join-code || { cat $LIVE/mac.log; fail "Mac не выдал код подключения"; }
print -- "[MyNotion/iMac] Mac подключён и выдал код ($(( SECONDS - started )) с)"

# 3. iPhone в симуляторе (сборка под симулятор, если её ещё нет в копии): подключиться кодом, дождаться страницы с Mac,
# открыть её и напечатать текст в редакторе.
[[ -d $WORK/build/iphone/Build/Products/Debug-iphonesimulator/MyNotion.app ]] \
  || (unset XCODE_XCCONFIG_FILE; xcodebuild build -scheme MyNotionPhone -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath build/iphone -jobs $JOBS -quiet) || fail "iPhone: MyNotionPhone не собрался"
boot_iphone_simulator
xcrun simctl keychain $DEVICE reset
xcrun simctl ui $DEVICE appearance light
# Экранная клавиатура, а не клавиатура iMac: она должна выехать на снимке.
defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false
xcrun simctl launch --terminate-running-process $DEVICE $BUNDLE --database $LIVE/phone.sqlite \
  --sync-server http://127.0.0.1:$PORT --sync-device-name 'iPhone Юрия' --sync-join-code-file $LIVE/join-code \
  --sync-log $LIVE/phone.log --live-check-page $PAGE --live-check-edit $EDIT --live-check-mac-edit $MAC_EDIT >/dev/null
wait_for 120 "страница с Mac на iPhone" grep -q page-arrived $LIVE/phone.log \
  || { cat $LIVE/phone.log; fail "Страница с Mac не появилась на iPhone"; }
print -- "[MyNotion/iMac] страница с Mac — на iPhone ($(( SECONDS - started )) с)"
xcrun simctl io $DEVICE screenshot $RESULTS/phone-tree.png >/dev/null 2>&1
wait_for 90 "правка ушла с iPhone" grep -q '^.* sent$' $LIVE/phone.log \
  || { cat $LIVE/phone.log; fail "Правка с iPhone не ушла на сервер"; }

# 4. Правка с iPhone — в базе Mac.
edited_block() { sqlite3 $LIVE/mac.sqlite "SELECT id FROM block WHERE isDeleted = 0 AND text LIKE '%$EDIT%' LIMIT 1"; }
mac_has_edit() { [[ -n $(edited_block) ]]; }
wait_for 90 "правка с iPhone на Mac" mac_has_edit || { cat $LIVE/mac.log; fail "Правка с iPhone не пришла на Mac"; }
print -- "[MyNotion/iMac] правка с iPhone — на Mac ($(( SECONDS - started )) с)"

# 5. Правка с Mac — под напечатанным на iPhone; должна появиться на открытой странице iPhone.
page_id=$(sed -n 's/.*page-arrived: //p' $LIVE/phone.log | head -1)
$APP/Contents/Helpers/mynotion block insert $page_id --kind paragraph --text $MAC_EDIT --after $(edited_block) \
  --socket $LIVE/control.sock --no-launch --agent live-check >/dev/null || fail "Mac: mynotion block insert не прошёл"
wait_for 90 "правка с Mac на открытой странице iPhone" grep -q mac-edit-visible $LIVE/phone.log \
  || { cat $LIVE/phone.log; fail "Правка с Mac не появилась на открытой странице iPhone"; }
print -- "[MyNotion/iMac] правка с Mac — на открытой странице iPhone ($(( SECONDS - started )) с)"

# 6. Снимки: страница с клавиатурой, она же в тёмной теме, экран iMac с окном Mac.
sleep 1
xcrun simctl io $DEVICE screenshot $RESULTS/phone-page-keyboard.png >/dev/null 2>&1
xcrun simctl ui $DEVICE appearance dark
sleep 2
xcrun simctl io $DEVICE screenshot $RESULTS/phone-page-dark.png >/dev/null 2>&1
xcrun simctl ui $DEVICE appearance light
screencapture -x $RESULTS/mac-screen.png 2>/dev/null || true
print -- "[MyNotion/iMac] iPhone: живая проверка пройдена — Mac → iPhone → Mac → iPhone за $(( SECONDS - started )) с"
