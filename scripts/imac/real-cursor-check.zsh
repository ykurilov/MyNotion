#!/bin/zsh
# Живая проверка указателя мыши на iMac настоящими событиями мыши (не XCUITest hover, не перенос курсора).
# Выполняется НА iMac внутри `imac-run --gui` (в копии проекта):
#
#   imac-run --gui --no-fallback --no-setup --wait 3000 --fetch build/real-cursor -- \
#     'zsh scripts/imac/real-cursor-check.zsh [page|inactive|window|both] [--skip-build]'
#
# both — page и window. inactive — page и затем окно MyNotion позади другого приложения.
# PROBE_MAX_X / PROBE_MAX_Y (экранные точки) — window проходит только часть окна.
#
# 1. Release-сборка, как у Юрия. 2. База с образцом: обложка gradients_3, иконка 📘, название, H1, абзац.
# 3. Приложение запускается обычным `open`, окно впереди. 4. real-cursor-probe ведёт мышь событиями
# CGEvent .mouseMoved и каждые 5 мс читает системный указатель. Журнал и итог — build/real-cursor/<режим>.log.
#
# События мыши macOS принимает только от процесса с правом «Универсальный доступ». На iMac оно выдано
# входу по SSH (пункт «sshd-keygen-wrapper»); без него probe сразу завершается с FAIL, а не «зеленеет».
set -euo pipefail
source ${0:A:h}/lib.sh

mode=${1:-page}; skip_build=${2:-}
OUT=$WORK/build/real-cursor
mkdir -p $OUT
require_toolchain
require_gui_session

if [[ $skip_build != --skip-build ]]; then
  build_app Release build/real-cursor-dd || fail "Release-сборка не удалась"
fi
APP=$WORK/build/real-cursor-dd/Build/Products/Release/MyNotion.app
[[ -d $APP ]] || fail "Нет Release-сборки $APP"
swiftc -O -swift-version 5 scripts/imac/real-cursor-probe.swift -o $OUT/real-cursor-probe 2> $OUT/probe-build.log \
  || fail "probe не собрался: $(cat $OUT/probe-build.log)"

# База: образец, затем обложка — прямо в строку страницы (так её хранит приложение).
DB=$OUT/library/MyNotion.sqlite
rm -rf $OUT/library; mkdir -p $OUT/library
# Гасим только свой экземпляр (по пути сборки): чужие MyNotion на iMac не трогаем.
quit_ours() { pkill -f "$APP/Contents/MacOS/MyNotion" 2>/dev/null || true; }
quit_ours
open -n $APP --args --database $DB --generate-visual-sample
for _ in {1..100}; do
  [[ $(sqlite3 $DB "SELECT count(*) FROM page WHERE title='MyNotion — образец'" 2>/dev/null) == 1 ]] && break
  sleep 0.2
done
sleep 1; quit_ours; sleep 1
sqlite3 $DB "UPDATE page SET cover='{\"source\":{\"gallery\":\"gradients_3\"},\"offset\":0.5}' WHERE title='MyNotion — образец'"
[[ $(sqlite3 $DB "SELECT icon IS NOT NULL AND cover IS NOT NULL FROM page WHERE title='MyNotion — образец'") == 1 ]] \
  || fail "Образец без иконки или обложки"

# Обычный запуск, как из Dock; окно на одном месте и одного размера.
open -n $APP --args --database $DB --appearance light "-NSWindow Frame pages-AppWindow-1" "156 76 1200 800 0 0 1512 952 "
for _ in {1..50}; do pgrep -f "$APP/Contents/MacOS/MyNotion" >/dev/null && break; sleep 0.2; done
sleep 3

pid=$(pgrep -f "$APP/Contents/MacOS/MyNotion" | head -1)
[[ -n $pid ]] || fail "MyNotion не запустился"
rc=0
modes=($mode); [[ $mode == both ]] && modes=(page window)
for m in $modes; do
  rm -f $OUT/$m.log
  $OUT/real-cursor-probe $pid $OUT/$m.log $m >/dev/null || rc=$?
  [[ -f $OUT/$m.log ]] || fail "probe не оставил журнала ($m, exit $rc)"
  cat $OUT/$m.log
done
quit_ours
exit $rc
