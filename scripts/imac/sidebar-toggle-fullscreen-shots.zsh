#!/bin/zsh
# Живая проверка шторки панели: снимки окна MyNotion в обычном окне, во весь экран и после возврата (CuaDriver).
# Запуск: scripts/imac/run-on-imac.sh lock -- zsh scripts/imac/sidebar-toggle-fullscreen-shots.zsh [папка снимков на iMac]
set -euo pipefail
export PATH=$HOME/.local/bin:$PATH
OUT=${1:-$HOME/work/shots/sidebar-toggle}
mkdir -p $OUT
source scripts/imac/lib.sh
build_app Debug build/imac-shots-dd
caffeinate -u -t 2
DB=$(mktemp -d)/MyNotion.sqlite
$APP/Contents/MacOS/MyNotion --database $DB -NSWindow\ Frame\ pages-AppWindow-1 "156 76 1200 800 0 0 1512 952 " >/dev/null 2>&1 &
PID=$!
sleep 6
# Закрываем без kill: убитое в полном экране приложение система открывает там же в следующий раз.
trap 'isfull && view_menu "Выйти из полноэкранного режима" >/dev/null 2>&1; osascript -e "tell application id \"cloud.kurilov.mynotion\" to quit" >/dev/null 2>&1; sleep 2; kill $PID 2>/dev/null || true' EXIT

windows() { cua-driver call list_windows "{\"pid\":$PID}"; }
wid() { windows | jq -r '.windows | map(select(.title!="" and .is_on_screen)) | .[0].window_id'; }
shot() { cua-driver call get_window_state "{\"pid\":$PID,\"window_id\":$(wid),\"screenshot_out_file\":\"$OUT/$1.png\"}" >/dev/null; echo "снимок $1"; }
# Окно во весь экран: на всю высоту экрана и от самого верха.
isfull() { windows | jq -e '.windows | any(.title!="" and .is_on_screen and .bounds.height>=1200 and .bounds.y==0)' >/dev/null; }
# Ждём, пока окно окажется в нужном режиме (переход идёт пару секунд): wait_mode full|window.
wait_mode() {
  for _ in {1..20}; do
    if isfull; then [[ $1 == full ]] && return 0; else [[ $1 == window ]] && return 0; fi
    sleep 1
  done
  return 1
}
# Пункт меню «Вид» через доступность (мышь и фокус не нужны); сразу после перехода меню ещё перестраивается — повторяем.
view_menu() {
  cua-driver call bring_to_front "{\"pid\":$PID}" >/dev/null; sleep 1
  for _ in {1..5}; do
    cua-driver call invoke_menu "{\"pid\":$PID,\"window_id\":$(wid),\"path\":[\"Вид\",\"$1\"]}" >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "FAIL: нет пункта «$1»"; exit 1
}

# Система помнит, что приложение закрыли во весь экран, и открывает его там же — сначала выходим.
isfull && view_menu "Выйти из полноэкранного режима"
wait_mode window || { echo "FAIL: не вышли из полного экрана"; exit 1; }
sleep 1; shot windowed

view_menu "Перейти в полноэкранный режим"
if wait_mode full; then sleep 2; shot fullscreen; else echo "FAIL: не вошли во весь экран"; windows | jq -c '.windows[] | select(.is_on_screen) | {title,bounds}'; exit 1; fi

view_menu "Выйти из полноэкранного режима"
wait_mode window || { echo "FAIL: не вернулись в окно"; exit 1; }
sleep 2; shot back-to-windowed
echo "OK"
