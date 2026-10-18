#!/bin/zsh
# Память в покое с включённой синхронизацией (T095, принцип II): сборка Release на эталонной базе
# в виртуальном Mac. Сервер из server/ — внутри виртуального Mac со своей временной базой (боевой не трогается).
# 1) Первый запуск подключает эталон токеном и отправляет все записи на сервер — память после отправки.
# 2) Второй запуск — синхронизация уже включена, правок нет — память в покое через 10 с и через 60 с.
#
#   scripts/vm/sync-memory-check.sh
set -euo pipefail

REPO=${0:A:h:h:h}
VM=$REPO/scripts/vm/run-in-vm.sh
if [[ ${MN_SYNC_MEMORY_INNER:-} != 1 ]]; then
  MN_SYNC_MEMORY_INNER=1 exec $VM lock -- zsh $0
fi

VM_USER=lume
SSH_KEY=~/.ssh/mynotion_vm_ed25519
DERIVED=${MYNOTION_VM_DD:-/tmp/mynotion-vm-dd}-release
PORT=39187
W=/tmp/mn-sync-memory
ip=$($VM ssh true >/dev/null && $VM status | awk '{print $2}')
[[ -n $ip ]] || { echo "Виртуальный Mac не отвечает" >&2; exit 1; }
vm() { ssh -i $SSH_KEY -o BatchMode=yes $VM_USER@$ip "$@"; }
push() { rsync -a -e "ssh -i $SSH_KEY" "$@"; }

# Сервер и приложение Release.
(cd $REPO/server && pnpm install --frozen-lockfile --silent && pnpm --silent build)
(cd $REPO && xcodegen generate -q && xcodebuild -scheme MyNotion -configuration Release -derivedDataPath $DERIVED build -quiet)
NODE=${$(command -v node):A}
vm "mkdir -p ~/mn-sync-server/bin; kill \$(cat $W/server.pid 2>/dev/null) 2>/dev/null || true; pkill -x MyNotion || true; rm -rf $W; mkdir -p $W"
push $NODE $VM_USER@$ip:/Users/$VM_USER/mn-sync-server/bin/node
push --delete $REPO/server/dist $REPO/server/node_modules $REPO/server/package.json $VM_USER@$ip:/Users/$VM_USER/mn-sync-server/app/
push --delete $DERIVED/Build/Products/Release/MyNotion.app $VM_USER@$ip:/Users/$VM_USER/
vm "cd ~/mn-sync-server/app && DATA_DIR=$W/server PORT=$PORT nohup ../bin/node dist/main.js > $W/server.log 2>&1 & echo \$! > $W/server.pid"
for _ in {1..50}; do vm "curl -sf http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; perl -e 'select(undef,undef,undef,0.2)'; done
vm "cd ~/mn-sync-server/app && DATA_DIR=$W/server ../bin/node dist/cli.js bootstrap --name 'Mac A' --token-only > $W/token"

# Эталонная база (1 000 страниц, 100 000 блоков) — её копия.
vm "pkill -9 -x SecurityAgent || true; mkdir -p ~/reflib; test -f ~/reflib/MyNotion.sqlite || ~/MyNotion.app/Contents/MacOS/MyNotion --generate-reference-library ~/reflib/MyNotion.sqlite >/dev/null; cp ~/reflib/MyNotion.sqlite $W/"

footprint_mb() { vm "footprint -p \$(pgrep -x MyNotion) 2>/dev/null | awk '/phys_footprint:/ {print \$2, \$3; exit}'"; }

# 1. Подключение и первая отправка всех записей.
vm "open -n ~/MyNotion.app --args --database $W/MyNotion.sqlite --sync-server http://127.0.0.1:$PORT --sync-device-name 'Mac A' \
  --sync-connect-token-file $W/token --sync-log $W/sync1.log --launch-report $W/launch1.json"
for _ in {1..120}; do vm "grep -q 'Все правки этого Mac отправлены' $W/sync1.log 2>/dev/null" && break; perl -e 'select(undef,undef,undef,1)'; done
echo "Первый запуск: $(vm "tail -1 $W/sync1.log")"
echo "Память после отправки всех записей: $(footprint_mb)"
vm "pkill -x MyNotion; for i in {1..50}; do pgrep -x MyNotion >/dev/null || break; sleep 0.2; done"

# 2. Повторный запуск: синхронизация включена, правок нет.
vm "open -n ~/MyNotion.app --args --database $W/MyNotion.sqlite --sync-log $W/sync2.log --launch-report $W/launch2.json"
for _ in {1..60}; do vm "grep -q idleMemoryBytes $W/launch2.json 2>/dev/null" && break; perl -e 'select(undef,undef,undef,1)'; done
echo "Повторный запуск (отчёт приложения): $(vm "cat $W/launch2.json")"
echo "Синхронизация: $(vm "tail -1 $W/sync2.log")"
perl -e 'select(undef,undef,undef,50)'
echo "Память через 60 с: $(footprint_mb)"

# Уборка: приложение, сервер, секреты синхронизации в связке ключей виртуального Mac.
vm "pkill -x MyNotion || true; kill \$(cat $W/server.pid) 2>/dev/null || true"
vm "while security delete-generic-password -s cloud.kurilov.mynotion.sync >/dev/null 2>&1; do :; done; pkill -9 -x SecurityAgent || true"
