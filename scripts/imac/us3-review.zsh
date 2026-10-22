#!/bin/zsh
# На iMac, только внутри scripts/imac/run-on-imac.sh lock -- 'zsh scripts/imac/us3-review.zsh'.
# Паузы перед кликами и перед живым Notion позволяют проверить снимки в том же GUI-слоте.
set -euo pipefail
source ${0:A:h}/lib.sh
out=$WORK/build/us3-review
mkdir -p $out/ui $out/native
rm -f $out/preflight-ready $out/continue-tests $out/native-ready $out/native.done
~/.local/bin/cua-driver call get_desktop_state "{\"screenshot_out_file\":\"$out/desktop.png\"}" > $out/desktop.json
~/.local/bin/cua-driver call list_windows '{}' > $out/windows.json
touch $out/preflight-ready
print -r -- "US3 preflight-ready: $out/desktop.png; требуется continue-tests после проверки экрана."
for attempt in {1..300}; do
  [[ -f $out/continue-tests ]] && break
  sleep 1
done
[[ -f $out/continue-tests ]] || { print -u2 'Preflight не подтверждён, клики не начаты'; exit 3; }
date > $out/context.log
uptime >> $out/context.log
ui_rc=0
zsh scripts/imac/on-imac.sh uitest -only-testing:UITests/ViewFilterSortGroupTests > $out/ui-run.log 2>&1 || ui_rc=$?
[[ -f build/imac-uitest/uitest.log ]] && cp build/imac-uitest/uitest.log $out/ui/uitest.log
[[ -d build/imac-uitest/attachments ]] && cp -R build/imac-uitest/attachments $out/ui/
print -r -- "ui_exit=$ui_rc" | tee $out/exit-codes.log
gallery_rc=0
zsh scripts/imac/on-imac.sh gallery --only view- > $out/gallery-run.log 2>&1 || gallery_rc=$?
print -r -- "gallery_exit=$gallery_rc" | tee -a $out/exit-codes.log
touch $out/native-ready
print -r -- 'US3 native-ready: GUI-слот удерживается для живой сверки Notion; по окончании создать native.done.'
for attempt in {1..600}; do
  [[ -f $out/native.done ]] && break
  sleep 1
done
[[ -f $out/native.done ]] || { print -u2 'Живая проверка Notion не завершена'; exit 3; }
cat $out/exit-codes.log
(( ui_rc == 0 && gallery_rc == 0 ))
