#!/bin/zsh
# На iMac, только внутри run-on-imac.sh lock. Одна согласованная серия без обхода очереди.
set -euo pipefail
[[ -e build ]] || ln -s .imac-runner-us3-build build
source ${0:A:h}/lib.sh
out=$WORK/build/us3-validation
mkdir -p $out
rm -f $out/preflight-ready $out/continue
~/.local/bin/cua-driver call get_desktop_state "{\"screenshot_out_file\":\"$out/desktop.png\"}" > $out/desktop.json
~/.local/bin/cua-driver call list_windows '{}' > $out/windows.json
touch $out/preflight-ready
print 'US3 validation preflight-ready, ждём continue после проверки экрана.'
for attempt in {1..300}; do
  [[ -f $out/continue ]] && break
  sleep 1
done
[[ -f $out/continue ]] || exit 3
rc=0
zsh scripts/imac/on-imac.sh uitest -only-testing:UITests/ViewFilterSortGroupTests/testFilterSortSearchHideGroupSecondViewAndRelaunch > $out/ui-run.log 2>&1 || rc=$?
mkdir -p $out/ui
cp build/imac-uitest/uitest.log $out/ui/
[[ -d build/imac-uitest/attachments ]] && cp -R build/imac-uitest/attachments $out/ui/
print -r -- "ui_exit=$rc" | tee $out/exit-codes.log
rc=0
zsh scripts/imac/on-imac.sh gallery --only view- > $out/gallery-run.log 2>&1 || rc=$?
print -r -- "gallery_exit=$rc" | tee -a $out/exit-codes.log
zsh scripts/imac/us3-control.zsh > $out/control-run.log 2>&1
rc=0
zsh scripts/imac/us3-profile.zsh > $out/profile-run.log 2>&1 || rc=$?
print -r -- "profile_exit=$rc (диагностический, не приёмочный)" | tee -a $out/exit-codes.log
