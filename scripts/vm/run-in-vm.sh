#!/bin/zsh
# Запуск MyNotion в виртуальном Mac (Cua/Lume), чтобы не трогать экран и фокус Юрия.
# На основном Mac приложение НЕ запускается никогда — только сборка.
#
#   scripts/vm/run-in-vm.sh gallery [--only <слово>] [--out <папка на этом Mac>]
#   scripts/vm/run-in-vm.sh run <флаги приложения...>      # любой служебный режим, вывод в консоль
#   scripts/vm/run-in-vm.sh ssh <команда>                   # команда внутри виртуального Mac
#   scripts/vm/run-in-vm.sh uitest [-only-testing:UITests/<Класс>]  # UI-тесты Xcode внутри
#   scripts/vm/run-in-vm.sh status
set -euo pipefail

VM_NAME=cua-base-3416f98dedcf
VM_STORAGE=ssd
VM_USER=lume
SSH_KEY=~/.ssh/mynotion_vm_ed25519
LUME_API=http://localhost:7777/lume
REPO=${0:A:h:h:h}
DERIVED=/tmp/mynotion-vm-dd
APP_LOCAL=$DERIVED/Build/Products/Debug/MyNotion.app
APP_REMOTE=/Users/$VM_USER/MyNotion.app

vm_ip() {
  curl -s "$LUME_API/vms/$VM_NAME" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('ipAddress') or '')"
}

ensure_vm_running() {
  local ip; ip=$(vm_ip)
  if [[ -z $ip ]]; then
    curl -s -X POST "$LUME_API/vms/$VM_NAME/run" -H 'Content-Type: application/json' \
      -d "{\"noDisplay\":true,\"storage\":\"$VM_STORAGE\"}" > /dev/null
    for _ in {1..60}; do ip=$(vm_ip); [[ -n $ip ]] && break; perl -e 'select(undef,undef,undef,5)'; done
  fi
  [[ -n $ip ]] || { echo "Виртуальный Mac не поднялся" >&2; exit 1; }
  for _ in {1..30}; do
    ssh -i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new $VM_USER@$ip true 2>/dev/null && break
    perl -e 'select(undef,undef,undef,5)'
  done
  echo $ip
}

vm_ssh() { local ip=$1; shift; ssh -i $SSH_KEY -o BatchMode=yes $VM_USER@$ip "$@"; }

build_and_push() {
  local ip=$1
  (cd $REPO && xcodegen generate -q && xcodebuild -scheme MyNotion -configuration Debug -derivedDataPath $DERIVED build -quiet)
  rsync -a --delete -e "ssh -i $SSH_KEY" $APP_LOCAL $VM_USER@$ip:/Users/$VM_USER/
}

# Экран как у ноутбука с ретиной — 1512×982 точек @2x: окно галереи 1440×900 влезает целиком, снимки @2x.
# Сам гость после перезапуска ставит 1024×768, поэтому режим ставится перед каждой галереей.
set_screen() {
  local ip=$1 tool=$DERIVED/displaymode
  [[ $tool -nt $REPO/scripts/vm/displaymode.swift ]] || swiftc -O $REPO/scripts/vm/displaymode.swift -o $tool
  scp -q -i $SSH_KEY $tool $VM_USER@$ip:/Users/$VM_USER/displaymode
  vm_ssh $ip "./displaymode 1512 982 && defaults write com.apple.dock autohide -bool true"
}

# Приложение запускается в GUI-сессии виртуального Mac через `open` (из SSH так можно, `launchctl asuser` — нет).
run_app() {
  local ip=$1; shift
  vm_ssh $ip "open -W -n $APP_REMOTE --stdout /tmp/mynotion.out --stderr /tmp/mynotion.err --args ${(q)@}; cat /tmp/mynotion.out /tmp/mynotion.err"
}

# Виртуальный Mac один на всех агентов: запуски идут по очереди (папка-замок; сбрасывается, если владелец умер).
LOCK=/tmp/mynotion-vm.lock
take_vm_lock() {
  until mkdir $LOCK 2>/dev/null; do
    local owner; owner=$(cat $LOCK/pid 2>/dev/null || true)
    if [[ -n $owner ]] && ! kill -0 $owner 2>/dev/null; then rm -rf $LOCK; continue; fi
    perl -e 'select(undef,undef,undef,3)'
  done
  echo $$ > $LOCK/pid
  trap 'rm -rf $LOCK' EXIT
}
[[ ${1:-} == (gallery|run|uitest) ]] && take_vm_lock

case ${1:-} in
  gallery)
    shift; only=(); out=/tmp/mynotion-gallery-vm-$(date +%H%M%S)
    while (( $# )); do case $1 in --only) only=(--ui-gallery-only $2); shift 2;; --out) out=$2; shift 2;; *) shift;; esac; done
    ip=$(ensure_vm_running); build_and_push $ip; set_screen $ip
    vm_ssh $ip "rm -rf ~/gallery && mkdir ~/gallery"
    run_app $ip --ui-gallery /Users/$VM_USER/gallery $only
    mkdir -p $out && rsync -a --delete -e "ssh -i $SSH_KEY" $VM_USER@$ip:/Users/$VM_USER/gallery/ $out/
    echo "Галерея: $out ($(ls $out | grep -c png) снимков)";;
  run)
    shift; ip=$(ensure_vm_running); build_and_push $ip; run_app $ip "$@";;
  uitest)
    # Штатные UI-тесты Xcode внутри виртуального Mac: сборка здесь, прогон там.
    #   scripts/vm/run-in-vm.sh uitest [-only-testing:UITests/<Класс>] ...
    shift; ip=$(ensure_vm_running); set_screen $ip
    (cd $REPO && xcodegen generate -q && xcodebuild -scheme MyNotion -derivedDataPath /tmp/mynotion-uitest-dd build-for-testing -quiet)
    rsync -a --delete -e "ssh -i $SSH_KEY" /tmp/mynotion-uitest-dd/Build/Products/ $VM_USER@$ip:/Users/$VM_USER/uitest-products/
    run=$(cd /tmp/mynotion-uitest-dd/Build/Products && ls *.xctestrun | head -1)
    vm_ssh $ip "cd ~/uitest-products && xcodebuild test-without-building -xctestrun $run -destination 'platform=macOS,arch=arm64' ${(q)@} 2>&1 | grep -E 'Test Case|error:|Executed|TEST (SUCCEEDED|FAILED)|not permitted|authoriz'";;
  ssh)
    shift; ip=$(ensure_vm_running); vm_ssh $ip "$@";;
  status)
    curl -s "$LUME_API/vms/$VM_NAME" | python3 -c "import json,sys;d=json.load(sys.stdin);print(d.get('status'), d.get('ipAddress'))";;
  *)
    sed -n '2,9p' $0; exit 1;;
esac
