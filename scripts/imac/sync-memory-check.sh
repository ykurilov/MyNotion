#!/bin/zsh
# Память в покое с включённой синхронизацией (T095, принцип II): сборка Release на эталонной базе на iMac.
# Сервер из server/ — на iMac со своей временной базой (боевой не трогается).
# 1) Первый запуск подключает эталон токеном и отправляет все записи на сервер — память после отправки.
# 2) Второй запуск — синхронизация уже включена, правок нет — память в покое через 10 с и через 60 с.
#
#   scripts/imac/sync-memory-check.sh
set -euo pipefail

REPO=${0:A:h:h:h}

if [[ ${MN_ON_IMAC:-} != 1 ]]; then
  cd $REPO
  exec imac-run --gui --no-fallback --no-setup --wait ${MYNOTION_IMAC_WAIT:-1800} -- 'MN_ON_IMAC=1 zsh scripts/imac/sync-memory-check.sh'
fi

# Дальше — на iMac, в копии проекта.
source ${0:A:h}/lib.sh
require_toolchain; require_gui_session

PORT=39187
W=/tmp/mn-sync-memory
# Эталонная база (1 000 страниц, 100 000 блоков) — одна на все копии кода, в служебной папке iMac.
REFLIB=~/.imac-runner/mynotion-reflib

stop_all() { pkill -x MyNotion 2>/dev/null || true; kill $(cat $W/server.pid 2>/dev/null) 2>/dev/null || true; }
trap stop_all EXIT INT TERM

# Сервер и приложение Release.
(cd server && pnpm install --frozen-lockfile --silent && pnpm --silent build)
build_app Release build/imac-dd-release
stop_all; rm -rf $W; mkdir -p $W
(cd server && DATA_DIR=$W/server PORT=$PORT nohup node dist/main.js > $W/server.log 2>&1 & echo $! > $W/server.pid)
for _ in {1..50}; do curl -sf http://127.0.0.1:$PORT/health >/dev/null 2>&1 && break; sleep 0.2; done
(cd server && DATA_DIR=$W/server node dist/cli.js bootstrap --name 'Mac A' --token-only > $W/token)

close_stale_prompts
mkdir -p $REFLIB
[[ -f $REFLIB/MyNotion.sqlite ]] || $APP/Contents/MacOS/MyNotion --generate-reference-library $REFLIB/MyNotion.sqlite >/dev/null
cp $REFLIB/MyNotion.sqlite $W/

footprint_mb() { footprint -p $(pgrep -x MyNotion) 2>/dev/null | awk '/phys_footprint:/ {print $2, $3; exit}'; }

# 1. Подключение и первая отправка всех записей.
open -n $APP --args --database $W/MyNotion.sqlite --sync-server http://127.0.0.1:$PORT --sync-device-name 'Mac A' \
  --sync-connect-token-file $W/token --sync-log $W/sync1.log --launch-report $W/launch1.json
for _ in {1..120}; do grep -q 'Все правки этого Mac отправлены' $W/sync1.log 2>/dev/null && break; sleep 1; done
echo "Первый запуск: $(tail -1 $W/sync1.log)"
echo "Память после отправки всех записей: $(footprint_mb)"
pkill -x MyNotion || true; for _ in {1..50}; do pgrep -x MyNotion >/dev/null || break; sleep 0.2; done

# 2. Повторный запуск: синхронизация включена, правок нет.
open -n $APP --args --database $W/MyNotion.sqlite --sync-log $W/sync2.log --launch-report $W/launch2.json
for _ in {1..60}; do grep -q idleMemoryBytes $W/launch2.json 2>/dev/null && break; sleep 1; done
echo "Повторный запуск (отчёт приложения): $(cat $W/launch2.json)"
echo "Синхронизация: $(tail -1 $W/sync2.log)"
sleep 50
echo "Память через 60 с: $(footprint_mb)"

# Уборка: приложение и сервер — в ловушке; секреты синхронизации в связке ключей.
stop_all
forget_sync_secrets
