#!/bin/zsh
# Сборка, запуск и UI-тесты MyNotion на iMac через `imac-run` (skill imac): основной Mac только правит код.
# Очередь imac-run сама делит iMac между агентами; всё с окнами берёт место «экран» (--gui).
#
#   scripts/imac/run-on-imac.sh gallery [--release] [--only <слово>] [--out <папка на этом Mac>]
#   scripts/imac/run-on-imac.sh run [--release] <флаги приложения...>     # любой служебный режим, вывод в консоль
#   scripts/imac/run-on-imac.sh uitest [--release] [-only-testing:UITests/<Класс>] [--out <папка>]
#   scripts/imac/run-on-imac.sh lock -- <команда>    # своя серия шагов в копии проекта на iMac, место «экран» занято
#   scripts/imac/run-on-imac.sh ssh <команда>        # быстрая команда на iMac (в копии проекта), без очереди
#   scripts/imac/run-on-imac.sh status               # очередь iMac, macOS, Xcode, автоматизация UI
#
# --release сразу после режима: сборка Release (замеры бюджета); для uitest — схема MyNotionPerformance.
# MYNOTION_IMAC_WAIT — сколько ждать место «экран», с (по умолчанию 1800).
set -euo pipefail

REPO=${0:A:h:h:h}
cd $REPO
WAIT=${MYNOTION_IMAC_WAIT:-1800}
IMAC_PATH='export PATH=$HOME/.local/bin:$HOME/.local/node/bin:$PATH'

mode=${1:-}; (( $# )) && shift
release=(); if [[ ${1:-} == --release ]]; then release=(--release); shift; fi

# Окна на основной Mac не переносятся никогда: --no-fallback; зависимости ставят сами сценарии: --no-setup.
on_imac_gui() { imac-run --gui --no-fallback --no-setup --wait $WAIT "$@"; }
# Одна строка для imac-run (одна строка — команда оболочки на iMac).
inner() { print -r -- "zsh scripts/imac/on-imac.sh ${(j: :)${(q)@}}"; }

# Итоги imac-run кладёт в <out>/<путь в проекте>, а openrsync (rsync в macOS) не понимает отметку «./»
# и кладёт их под полным путём копии на iMac — ищем папку, где бы она ни оказалась, и переносим, куда просили.
fetch_to() {
  local stage=$1 rel=$2 out=$3 src
  src=($stage/$rel(N/) $stage/**/$rel(N/D))
  if (( $#src )); then rm -rf $out; mkdir -p ${out:h}; mv $src[1] $out; fi
  rm -rf $stage
}

# Папка копии проекта на iMac — так же, как её называет imac-run.
imac_workdir() {
  local dir; dir=$(git rev-parse --show-toplevel)
  print -r -- ".imac-runner/work/$(basename "$dir" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-40)-$(printf '%s' "$dir" | shasum | cut -c1-8)"
}

case $mode in
  gallery)
    args=() out=/tmp/mynotion-gallery-imac-$(date +%H%M%S)
    while (( $# )); do case $1 in --only) args+=(--only $2); shift 2;; --out) out=$2; shift 2;; *) shift;; esac; done
    stage=$(mktemp -d /tmp/mynotion-imac.XXXXXX); rc=0
    on_imac_gui --fetch build/imac-gallery --out $stage -- "$(inner gallery $release $args)" || rc=$?
    fetch_to $stage build/imac-gallery $out
    [[ -d $out ]] && print -- "Галерея: $out ($(ls $out | grep -c png || true) снимков)"
    exit $rc;;
  run)
    on_imac_gui -- "$(inner run $release "$@")";;
  uitest)
    args=() out=/tmp/mynotion-uitest-imac-$(date +%H%M%S)
    while (( $# )); do case $1 in --out) out=$2; shift 2;; *) args+=($1); shift;; esac; done
    stage=$(mktemp -d /tmp/mynotion-imac.XXXXXX); rc=0
    on_imac_gui --fetch build/imac-uitest/uitest.log --fetch build/imac-uitest/attachments --fetch build/imac-uitest/probe-shots \
      --out $stage -- "$(inner uitest $release $args)" || rc=$?
    fetch_to $stage build/imac-uitest $out
    [[ -d $out ]] && print -- "Журнал и снимки: $out"
    exit $rc;;
  lock)
    [[ ${1:-} == -- ]] && shift
    on_imac_gui -- "$IMAC_PATH; $*";;
  ssh)
    ssh imac "$IMAC_PATH; cd ~/$(imac_workdir) 2>/dev/null || cd ~; $*";;
  status)
    imac-run --status
    ssh imac "$IMAC_PATH; echo \"macOS \$(sw_vers -productVersion)\"; xcodebuild -version 2>/dev/null | head -1 || echo 'Xcode не выбран';
      command -v xcodegen >/dev/null && echo 'xcodegen есть' || echo 'xcodegen нет'; DevToolsSecurity -status; automationmodetool 2>/dev/null | tail -1";;
  *)
    sed -n '2,15p' $0; exit 1;;
esac
