#!/bin/zsh
# На iMac, только внутри run-on-imac.sh lock. Одна согласованная серия без обхода очереди.
set -euo pipefail
[[ -e build ]] || ln -s .imac-runner-us3-build build
source ${0:A:h}/lib.sh
out=$WORK/build/us3-validation-4961489-$(date +%Y%m%d-%H%M%S)
mkdir -p $out
print -r -- "$out" > $WORK/build/us3-validation-current
# При блокировке инструментов не читать старые UI-артефакты как новый прогон.
xcodebuild -checkFirstLaunchStatus > $out/toolchain-status.log 2>&1
[[ ! -d build/imac-uitest ]] || mv build/imac-uitest $out/preexisting-uitest
[[ ! -d build/imac-gallery ]] || mv build/imac-gallery $out/preexisting-gallery
rm -f $out/preflight-ready $out/continue $out/abort
~/.local/bin/cua-driver call get_desktop_state "{\"screenshot_out_file\":\"$out/desktop.png\"}" > $out/desktop.json
~/.local/bin/cua-driver call list_windows '{}' > $out/windows.json
touch $out/preflight-ready
print 'US3 validation preflight-ready, ждём continue после проверки экрана.'
for attempt in {1..300}; do
  [[ -f $out/abort ]] && { print -u2 'Preflight остановлен: экран перекрыт или заблокирован'; exit 3; }
  [[ -f $out/continue ]] && break
  sleep 1
done
[[ -f $out/continue ]] || exit 3
# Проверка геометрии/resize/cleanup и затронутых страниц до кликающего сценария.
if [[ ${1:-} != --skip-unit ]]; then
  (cd Packages/MyNotionKit && swift test --scratch-path "$WORK/build/us3-swiftpm" --jobs 4 --filter DatabaseViewBarTests) > $out/unit.log 2>&1
fi
stage() { print -r -- "$1" | tee $out/stage; date >> $out/context.log; uptime >> $out/context.log; }
failed=0
stage UI
rc=0
zsh scripts/imac/on-imac.sh uitest -only-testing:UITests/ViewFilterSortGroupTests > $out/ui-run.log 2>&1 || rc=$?
if [[ -d build/imac-uitest ]]; then
  mv build/imac-uitest $out/ui
else
  print 'Свежий UI result не создан; проверить ui-run.log (сборка могла остановиться до теста).'
fi
print -r -- "ui_exit=$rc" | tee $out/exit-codes.log
(( rc == 0 )) || failed=1
stage gallery
rc=0
zsh scripts/imac/on-imac.sh gallery --only view- > $out/gallery-run.log 2>&1 || rc=$?
[[ ! -d build/imac-gallery ]] || mv build/imac-gallery $out/gallery
print -r -- "gallery_exit=$rc" | tee -a $out/exit-codes.log
(( rc == 0 )) || failed=1
# Обычный бюджет вида без sample: единственный источник приёмочных цифр после правок.
stage view-budget
view_rc=0
zsh scripts/imac/on-imac.sh uitest --release -only-testing:PerformanceTests/DatabaseViewPerformanceTests > $out/view-budget-run.log 2>&1 || view_rc=$?
if [[ -d build/imac-uitest ]]; then
  mv build/imac-uitest $out/view-budget
else
  print 'Свежий budget result не создан; проверить view-budget-run.log.'
fi
print -r -- "view_budget_exit=$view_rc" | tee -a $out/exit-codes.log
(( view_rc == 0 )) || failed=1
stage control
rc=0
zsh scripts/imac/us3-control.zsh > $out/control-run.log 2>&1 || rc=$?
print -r -- "control_exit=$rc" | tee -a $out/exit-codes.log
(( rc == 0 )) || failed=1
# Собственный SQL-путь уже профилирован; повтор sample без новой гипотезы не занимает GUI.
stage finished
exit $failed
