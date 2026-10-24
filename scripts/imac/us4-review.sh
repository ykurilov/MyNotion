#!/bin/bash
# Только на iMac через run-on-imac.sh lock после передачи GUI от US3.
# build/us4-joint27-prebuild/build.exit=0 обязателен; marker run-ui — после осмотра desktop.
set +e
# rsync защищает .imac-runner-*; обычный build может удаляться при следующем sync.
test -e build || ln -s .imac-runner-us4-build build
review=build/us4-joint27-review
if test "$(cat build/us4-joint27-prebuild/build.exit 2>/dev/null)" != 0; then
  echo "blocked: current Debug prebuild did not pass"
  exit 3
fi
mkdir -p "$review"
rm -f "$review/run-ui"
# Разрешённое пробуждение погасшего дисплея; настройки блокировки не меняются.
caffeinate -u -t 2
ioreg -n Root -d1 > "$review/session.txt"
~/.local/bin/cua-driver call get_desktop_state "{\"screenshot_out_file\":\"$PWD/$review/desktop.png\"}" > "$review/desktop.json" 2>&1
~/.local/bin/cua-driver call list_windows '{"on_screen_only":true}' > "$review/windows.json" 2>&1
if grep -q 'CGSSessionScreenIsLocked.*Yes' "$review/session.txt"; then
  echo 'blocked: session locked' > "$review/blocked.txt"
  exit 2
fi
echo US4_FINAL_PREFLIGHT_READY
for attempt in {1..120}; do
  test -f "$review/run-ui" && break
  sleep 1
done
if test ! -f "$review/run-ui"; then
  echo 'blocked: desktop inspection not completed' > "$review/blocked.txt"
  exit 2
fi
zsh -c 'set -euo pipefail; source scripts/imac/lib.sh; require_toolchain; require_gui_session; require_ui_automation; close_stale_prompts; xctest_run build/imac-uitest-dd/Build/Products build/imac-uitest -only-testing:UITests/RelationRollupTests' > "$review/ui.log" 2>&1
echo $? > "$review/ui.exit"
mkdir -p "$review/ui"
cp build/imac-uitest/uitest.log "$review/ui/" 2>/dev/null
test ! -d build/imac-uitest/attachments || cp -R build/imac-uitest/attachments "$review/ui/"
for scene in relation rollup; do
  zsh -c 'set -euo pipefail; source scripts/imac/lib.sh; require_toolchain; require_gui_session; close_stale_prompts; APP=$WORK/build/imac-uitest-dd/Build/Products/Debug/MyNotion.app; mkdir -p $WORK/build/us4-joint27-review/gallery-$1; run_app --ui-gallery $WORK/build/us4-joint27-review/gallery-$1 --ui-gallery-only $1' us4-gallery "$scene" > "$review/gallery-$scene.log" 2>&1
  echo $? > "$review/gallery-$scene.exit"
done
MN_ON_IMAC=1 MN_LIVE_TEST=SyncRelationsTwoMacsUITests zsh scripts/imac/sync-live-check.sh > "$review/live.log" 2>&1
echo $? > "$review/live.exit"
mkdir -p "$review/live"
cp build/imac-sync-live/*.log "$review/live/" 2>/dev/null
test ! -d build/imac-sync-live/attachments || cp -R build/imac-sync-live/attachments "$review/live/"
failed=0
for stage in ui gallery-relation gallery-rollup live; do
  test "$(cat "$review/$stage.exit")" = 0 || failed=1
done
echo US4_FINAL_GUI_FINISHED
cat "$review/ui.exit" "$review/gallery-relation.exit" "$review/gallery-rollup.exit" "$review/live.exit"

exit "$failed"
