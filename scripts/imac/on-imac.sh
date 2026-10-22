#!/bin/zsh
# Выполняется НА iMac внутри `imac-run` (в копии проекта). Напрямую не запускать — только через
# scripts/imac/run-on-imac.sh: он копирует проект, занимает место «экран» и забирает итоги назад.
#
#   on-imac.sh gallery [--release] [--only <слово>]
#   on-imac.sh run [--release] <флаги приложения...>
#   on-imac.sh uitest [--release] [-only-testing:UITests/<Класс>] ...
set -euo pipefail
source ${0:A:h}/lib.sh

mode=${1:-}; shift || true
CONFIG=Debug DD=build/imac-dd UITEST_DD=build/imac-uitest-dd
if [[ ${1:-} == --release ]]; then CONFIG=Release DD=$DD-release UITEST_DD=$UITEST_DD-release; shift; fi

require_toolchain
require_gui_session

case $mode in
  gallery)
    only=()
    while (( $# )); do case $1 in --only) only=(--ui-gallery-only $2); shift 2;; *) shift;; esac; done
    build_app $CONFIG $DD || exit $?; close_stale_prompts
    rm -rf build/imac-gallery; mkdir -p build/imac-gallery
    run_app --ui-gallery $WORK/build/imac-gallery $only
    print -- "Снимков: $(ls build/imac-gallery | grep -c png || true)";;
  run)
    build_app $CONFIG $DD || exit $?; close_stale_prompts; run_app "$@";;
  uitest)
    require_ui_automation; close_stale_prompts
    scheme=MyNotion; [[ $CONFIG == Release ]] && scheme=MyNotionPerformance
    xcodegen generate -q || exit $?
    xcodebuild -scheme $scheme -configuration $CONFIG -derivedDataPath $UITEST_DD -jobs $JOBS build-for-testing -quiet || exit $?
    xctest_run $UITEST_DD/Build/Products build/imac-uitest "$@";;
  *)
    sed -n '2,8p' $0; exit 2;;
esac
