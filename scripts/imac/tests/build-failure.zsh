#!/bin/zsh
# Лёгкая shell-регрессия, без Xcode/Swift, приложения и iMac: все внешние действия заменены функциями.
set -euo pipefail
repo=${0:A:h:h:h:h}
fixture=$(mktemp -d /tmp/mynotion-build-failure.XXXXXX)
trap 'rm -rf "$fixture"' EXIT
cp $repo/scripts/imac/{lib.sh,on-imac.sh,sync-memory-check.sh} $fixture/
cat >> $fixture/lib.sh <<'STUB'
require_toolchain() { :; }
require_gui_session() { :; }
require_ui_automation() { :; }
close_stale_prompts() { :; }
xcodegen() { print generator >> $MARKERS; return ${GEN_RC:-0}; }
xcodebuild() { print build >> $MARKERS; return ${BUILD_RC:-0}; }
run_app() { print launch >> $MARKERS; }
xctest_run() { print test >> $MARKERS; }
# У legacy memory helper не должна сработать даже его cleanup-ловушка при build failure.
pkill() { print unsafe-cleanup >> $MARKERS; }
kill() { print unsafe-cleanup >> $MARKERS; }
pnpm() { :; }
STUB
export MARKERS=$fixture/markers
cd $fixture
mkdir server
checks=0
for context in conditional or pipeline; do
  for failure in generator build; do
    export GEN_RC=0 BUILD_RC=0
    expected=69
    [[ $failure == generator ]] && GEN_RC=42 expected=42 || BUILD_RC=69
    : > $MARKERS
    actual=0
    CONTEXT=$context zsh -c '
      set -euo pipefail
      source ./lib.sh
      APP=stale.app
      rc=0
      case $CONTEXT in
        conditional) if build_app Debug build/dd; then exit 99; else rc=$?; fi;;
        or) build_app Debug build/dd || rc=$?;;
        pipeline) (build_app Debug build/dd || { rc=$?; [[ -z ${APP:-} ]] || exit 98; exit $rc; }) | cat || rc=$?;;
      esac
      [[ $CONTEXT == pipeline || -z ${APP:-} ]] || exit 98
      exit $rc
    ' || actual=$?
    [[ $actual == $expected ]] || { print -u2 "FAIL $context/$failure: $actual != $expected"; exit 1; }
    [[ $failure != generator ]] || ! grep -qx build $MARKERS
    (( ++checks ))
  done
done
for mode in gallery run uitest memory; do
  for failure in generator build; do
    export GEN_RC=0 BUILD_RC=0
    expected=69
    [[ $failure == generator ]] && GEN_RC=42 expected=42 || BUILD_RC=69
    : > $MARKERS
    actual=0
    if [[ $mode == memory ]]; then
      MN_ON_IMAC=1 zsh ./sync-memory-check.sh > $fixture/output 2>&1 || actual=$?
    else
      zsh ./on-imac.sh $mode > $fixture/output 2>&1 || actual=$?
    fi
    [[ $actual == $expected ]] || { cat $fixture/output; print -u2 "FAIL $mode/$failure: $actual != $expected"; exit 1; }
    ! grep -Eq '^(launch|test|unsafe-cleanup)$' $MARKERS
    [[ $failure != generator ]] || ! grep -qx build $MARKERS
    (( ++checks ))
  done
done
export GEN_RC=0 BUILD_RC=0
zsh -c 'set -euo pipefail; source ./lib.sh; APP=stale.app; build_app Debug build/dd; [[ $APP == $PWD/build/dd/Build/Products/Debug/MyNotion.app ]]'
(( ++checks ))
print -- "PASS: $checks shell checks; failure codes preserved, no stale App/test/cleanup launched"
