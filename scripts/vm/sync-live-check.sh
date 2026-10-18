#!/bin/zsh
# Живая проверка синхронизации двумя экземплярами MyNotion в виртуальном Mac (quickstart.md, US5).
# Сервер из server/ этой копии кода поднимается внутри виртуального Mac со своей временной базой и портом;
# первый экземпляр подключается токеном bootstrap, второй (копия приложения со своим bundle id) — кодом.
# Боевой сервер не трогается. Итог: задержки и снимки обоих окон в --out.
#
#   scripts/vm/sync-live-check.sh [--out <папка на этом Mac>]
set -euo pipefail

REPO=${0:A:h:h:h}
VM=$REPO/scripts/vm/run-in-vm.sh
OUT=/tmp/mn-sync-live-$(date +%H%M%S)
[[ ${1:-} == --out ]] && OUT=$2

if [[ ${MN_SYNC_LIVE_INNER:-} != 1 ]]; then
  # Всё дальнейшее — под общим замком виртуального Mac.
  MN_SYNC_LIVE_INNER=1 exec $VM lock -- zsh $0 --out $OUT
fi

VM_USER=lume
SSH_KEY=~/.ssh/mynotion_vm_ed25519
UITEST_DERIVED=${MYNOTION_UITEST_DD:-/tmp/mynotion-uitest-dd}
PORT=39123
ip=$($VM ssh true >/dev/null && $VM status | awk '{print $2}')
[[ -n $ip ]] || { echo "Виртуальный Mac не отвечает" >&2; exit 1; }
vm() { ssh -i $SSH_KEY -o BatchMode=yes $VM_USER@$ip "$@"; }
push() { rsync -a -e "ssh -i $SSH_KEY" "$@"; }

# 1. Сервер: собранный server/ и тот же node, под который собран better-sqlite3.
(cd $REPO/server && pnpm install --frozen-lockfile --silent && pnpm --silent build)
NODE=${$(command -v node):A}
vm "mkdir -p ~/mn-sync-server/bin; pkill -f 'mn-sync-server/bin/node' || true; pkill -f 'MyNotion.*.app/Contents/MacOS' || true; rm -rf /tmp/mn-sync-live; mkdir -p /tmp/mn-sync-live"
push $NODE $VM_USER@$ip:/Users/$VM_USER/mn-sync-server/bin/node
push --delete $REPO/server/dist $REPO/server/node_modules $REPO/server/package.json $VM_USER@$ip:/Users/$VM_USER/mn-sync-server/app/
vm "cd ~/mn-sync-server/app && DATA_DIR=/tmp/mn-sync-live/server PORT=$PORT nohup ../bin/node dist/main.js > /tmp/mn-sync-live/server.log 2>&1 & echo \$! > /tmp/mn-sync-live/server.pid"
for _ in {1..50}; do vm "curl -sf http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break; perl -e 'select(undef,undef,undef,0.2)'; done
vm "cd ~/mn-sync-server/app && DATA_DIR=/tmp/mn-sync-live/server ../bin/node dist/cli.js bootstrap --name 'Mac A' --token-only > /tmp/mn-sync-live/token && echo http://127.0.0.1:$PORT > /tmp/mn-sync-live/server-url"

# 2. Приложение для UI-теста и его копия со своим bundle id — «второй Mac».
(cd $REPO && xcodegen generate -q && xcodebuild -scheme MyNotion -derivedDataPath $UITEST_DERIVED build-for-testing -quiet)
push --delete $UITEST_DERIVED/Build/Products/ $VM_USER@$ip:/Users/$VM_USER/uitest-products/
vm "rm -rf /tmp/mn-sync-live/MyNotionB.app && cp -R ~/uitest-products/Debug/MyNotion.app /tmp/mn-sync-live/MyNotionB.app \
  && /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier cloud.kurilov.mynotion.second' /tmp/mn-sync-live/MyNotionB.app/Contents/Info.plist \
  && codesign --force --deep -s - /tmp/mn-sync-live/MyNotionB.app 2>/dev/null"

# 3. UI-тест в GUI-сессии (режим автоматизации включается только оттуда), ждём файл-итог.
run=$(cd $UITEST_DERIVED/Build/Products && ls *.xctestrun | head -1)
vm "cat > ~/run-uitest.command <<SCRIPT
#!/bin/zsh
cd ~/uitest-products
rm -rf ~/sync-live.xcresult; xcodebuild test-without-building -xctestrun $run -destination 'platform=macOS,arch=arm64' -only-testing:UITests/SyncTwoMacsUITests -resultBundlePath ~/sync-live.xcresult > ~/uitest.log 2>&1
echo \\\$? > ~/uitest.done
osascript -e 'tell application \"Terminal\" to quit' &
SCRIPT
chmod +x ~/run-uitest.command; rm -f ~/uitest.done ~/uitest.log; open ~/run-uitest.command"
for _ in {1..120}; do vm "test -f ~/uitest.done" && break; perl -e 'select(undef,undef,undef,5)'; done

# 4. Итог и уборка: сервер остановлен, база сервера и экземпляров — во временной папке виртуального Mac.
mkdir -p $OUT
vm "grep -E 'Test Case .*(passed|failed|skipped)|error:|XCTAssert|Задержка|TEST (EXECUTE )?(SUCCEEDED|FAILED)' ~/uitest.log | tail -20; echo exit=\$(cat ~/uitest.done 2>/dev/null)"
vm "rm -rf /tmp/mn-sync-live/shots; xcrun xcresulttool export attachments --path ~/sync-live.xcresult --output-path /tmp/mn-sync-live/shots >/dev/null 2>&1; cd /tmp/mn-sync-live/shots 2>/dev/null && python3 -c \"import json;[__import__('os').rename(a['exportedFileName'],a['suggestedHumanReadableName']) for t in json.load(open('manifest.json')) for a in t['attachments']]\" 2>/dev/null; ls /tmp/mn-sync-live/shots"
vm "cat /tmp/mn-sync-live/mac-a.log /tmp/mn-sync-live/mac-b.log 2>/dev/null; kill \$(cat /tmp/mn-sync-live/server.pid) 2>/dev/null || true"
push "$VM_USER@$ip:/tmp/mn-sync-live/shots/" "$VM_USER@$ip:/tmp/mn-sync-live/server.log" $OUT/ 2>/dev/null || true
echo "Итог: $OUT"
