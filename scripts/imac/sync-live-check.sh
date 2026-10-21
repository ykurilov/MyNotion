#!/bin/zsh
# Живая проверка синхронизации двумя экземплярами MyNotion на iMac (quickstart.md, US5).
# Сервер из server/ этой копии кода поднимается на iMac со своей временной базой и портом;
# первый экземпляр подключается токеном bootstrap, второй (копия приложения со своим bundle id) — кодом.
# Боевой сервер не трогается. Итог: задержки и снимки обоих окон в --out.
#
#   scripts/imac/sync-live-check.sh [--out <папка на этом Mac>]
set -euo pipefail

REPO=${0:A:h:h:h}

if [[ ${MN_ON_IMAC:-} != 1 ]]; then
  # Основной Mac: весь сценарий — одной серией на iMac под местом «экран».
  OUT=/tmp/mn-sync-live-$(date +%H%M%S); [[ ${1:-} == --out ]] && OUT=$2
  cd $REPO; stage=$(mktemp -d /tmp/mynotion-imac.XXXXXX); rc=0
  imac-run --gui --no-fallback --no-setup --wait ${MYNOTION_IMAC_WAIT:-1800} --fetch build/imac-sync-live --out $stage \
    -- 'MN_ON_IMAC=1 zsh scripts/imac/sync-live-check.sh' || rc=$?
  if [[ -d $stage/build/imac-sync-live ]]; then rm -rf $OUT; mkdir -p ${OUT:h}; mv $stage/build/imac-sync-live $OUT; print -- "Итог: $OUT"; fi
  rm -rf $stage; exit $rc
fi

# Дальше — на iMac, в копии проекта.
source ${0:A:h}/lib.sh
require_toolchain; require_gui_session; require_ui_automation

PORT=39123
LIVE=/tmp/mn-sync-live            # этот путь читает UITests/SyncTwoMacsUITests
UITEST_DD=build/imac-uitest-dd
RESULTS=build/imac-sync-live

# Свой сервер гасится при любом выходе: по номеру процесса и по порту. Адрес стирается: обычный прогон
# UI-тестов пропускает проверку двух Mac.
stop_server() {
  local pid
  pid=$(cat $LIVE/server.pid 2>/dev/null || true); [[ -n $pid ]] && kill $pid 2>/dev/null || true
  pid=$(lsof -tiTCP:$PORT -sTCP:LISTEN 2>/dev/null || true); [[ -n $pid ]] && kill $pid 2>/dev/null || true
  pkill -f 'MyNotion.*.app/Contents/MacOS' 2>/dev/null || true
  rm -f $LIVE/server-url
}
trap stop_server EXIT INT TERM

# 1. Сервер на iMac.
(cd server && pnpm install --frozen-lockfile --silent && pnpm --silent build)
stop_server
rm -rf $LIVE; mkdir -p $LIVE
(cd server && DATA_DIR=$LIVE/server PORT=$PORT nohup node dist/main.js > $LIVE/server.log 2>&1 & echo $! > $LIVE/server.pid)
for _ in {1..50}; do curl -sf http://127.0.0.1:$PORT/health >/dev/null 2>&1 && break; sleep 0.2; done
(cd server && DATA_DIR=$LIVE/server node dist/cli.js bootstrap --name 'Mac A' --token-only > $LIVE/token)
echo http://127.0.0.1:$PORT > $LIVE/server-url

# 2. Приложение для UI-теста и его копия со своим bundle id — «второй Mac».
xcodegen generate -q
xcodebuild -scheme MyNotion -derivedDataPath $UITEST_DD -jobs $JOBS build-for-testing -quiet
cp -R $UITEST_DD/Build/Products/Debug/MyNotion.app $LIVE/MyNotionB.app
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier cloud.kurilov.mynotion.second' $LIVE/MyNotionB.app/Contents/Info.plist
codesign --force --deep -s - $LIVE/MyNotionB.app 2>/dev/null

# 3. UI-тест.
close_stale_prompts; rc=0
xctest_run $UITEST_DD/Build/Products $RESULTS -only-testing:UITests/SyncTwoMacsUITests || rc=$?

# 4. Журналы экземпляров и сервера — к итогам; уборка секретов в связке ключей.
cat $LIVE/mac-a.log $LIVE/mac-b.log 2>/dev/null || true
cp $LIVE/server.log $LIVE/mac-a.log $LIVE/mac-b.log $RESULTS/ 2>/dev/null || true
forget_sync_secrets
exit $rc
