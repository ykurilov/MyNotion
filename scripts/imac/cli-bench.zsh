#!/bin/zsh
# На iMac внутри `run-on-imac.sh lock --` (место «экран»): замеры команды `mynotion` на Release (005, T070).
#   1. ответ (SC-402): 200 вызовов `page get` и 200 `block update` подряд на эталоне 004 (--generate-004-sample),
#      приложение запущено; время — от запуска клиента до конца его работы, p50/p95/максимум;
#   2. покой (SC-406): процессор с открытым сокетом без команд, `top -l 5`; память — `footprint`.
# Запуск и память в покое против 004 — тест бюджета `PerformanceTests/LaunchAndMemoryTests` (run-on-imac.sh uitest --release).
# Итоги — в build/cli-bench/summary.txt.
set -uo pipefail
zmodload zsh/datetime  # EPOCHREALTIME
source ${0:A:h}/lib.sh
require_toolchain
require_gui_session
out=$WORK/build/cli-bench
rm -rf $out; mkdir -p $out
summary=$out/summary.txt
note() { print -r -- "$*" | tee -a $summary; }
calls=${BENCH_CALLS:-200}

build_app Release build/cli-live-dd > $out/build.log 2>&1 || { tail -20 $out/build.log; fail "Сборка Release не прошла" }
pgrep -x MyNotion > /dev/null && fail "На iMac уже запущен MyNotion: замер в покое невозможен."

dir=/tmp/mnbench; rm -rf $dir; mkdir -p $dir   # короткий путь: сокет рядом с базой
mn() { $APP/Contents/Helpers/mynotion "$@" --socket $dir/control.sock --no-launch --agent bench }
open -g -n $APP --args --database $dir/MyNotion.sqlite --generate-004-sample
for t in {1..600}; do [[ -S $dir/control.sock ]] && break; sleep 0.2; done
mn app status > $out/status.json 2>&1
grep -q '"ok":true' $out/status.json || { cat $out/status.json; fail "Приложение с эталоном 004 не отвечает" }
wait_for_quiet_indexer | tee -a $summary

footprint_mb() { footprint -p $1 2>/dev/null | awk '/phys_footprint:/ { v = $2; u = $3 } END { if (u == "KB") v /= 1024; if (u == "GB") v *= 1024; printf "%.1f", v }' }
pid=$(pgrep -nf "$APP/Contents/MacOS/MyNotion")
sleep 10
memory_before=$(footprint_mb $pid)

# Страница с тремя абзацами: у неё берётся `page get`, а правится первый абзац.
print -r -- $'Первый абзац\n\nВторой абзац\n\nТретий абзац' > $dir/bench.md
mn page create --title Замер --markdown $dir/bench.md > $out/create.json 2>&1
note "  память после первой записи (page create): $(footprint_mb $pid) МБ"
page=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"]["page"]["id"])' $out/create.json)
mn page read $page --format json > $out/blocks.json 2>&1
note "  память после page read: $(footprint_mb $pid) МБ"
block=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"]["blocks"][0]["id"])' $out/blocks.json)
[[ -n $page && -n $block ]] || fail "Страница для замера не создалась"

percentiles() {   # percentiles <метка> <мс...>; p95_last — последний p95
  local label=$1; shift
  local line; line=$(python3 -I -c 'import sys
v = sorted(float(x) for x in sys.argv[1:]); n = len(v)
print(f"{n} {v[(n + 1) // 2 - 1]:.0f} {v[-(-n * 95 // 100) - 1]:.0f} {v[-1]:.0f} {v[-(-n * 95 // 100) - 1]:.3f}")' "$@")
  local f=(${=line})
  note "$label, $f[1] вызовов подряд: p50 $f[2] мс, p95 $f[3] мс, максимум $f[4] мс"
  p95_last=$f[5]
}

note "  память перед прогревом: $(footprint_mb $pid) МБ"
started_at=$(date '+%Y-%m-%d %H:%M:%S')
for i in {1..10}; do mn page get $page > /dev/null 2>&1; mn block update $block --text "прогрев $i" > /dev/null 2>&1; done

times=()
for i in {1..$calls}; do
  started=$EPOCHREALTIME
  mn page get $page > /dev/null 2>&1
  times+=($(( (EPOCHREALTIME - started) * 1000 )))
done
percentiles "page get (с запуском клиента)" $times
note "  память после page get: $(footprint_mb $pid) МБ"
get_p95=$p95_last

times=()
for i in {1..$calls}; do
  started=$EPOCHREALTIME
  mn block update $block --text "замер $i" > /dev/null 2>&1
  times+=($(( (EPOCHREALTIME - started) * 1000 )))
done
percentiles "block update (с запуском клиента)" $times
note "  память после block update: $(footprint_mb $pid) МБ"
update_p95=$p95_last

# Для справки: чтение содержимого берёт названия всех страниц для ссылок и упоминаний — читает дерево целиком.
times=()
for i in {1..30}; do
  started=$EPOCHREALTIME
  mn page read $page > /dev/null 2>&1
  times+=($(( (EPOCHREALTIME - started) * 1000 )))
done
percentiles "page read (справка, не из цели SC-402)" $times
note "  память после page read: $(footprint_mb $pid) МБ"

# Пустой клиент — сколько из этого стоит сам запуск процесса `mynotion` (справка не ходит в сокет).
times=()
for i in {1..50}; do
  started=$EPOCHREALTIME
  $APP/Contents/Helpers/mynotion --help > /dev/null 2>&1
  times+=($(( (EPOCHREALTIME - started) * 1000 )))
done
percentiles "mynotion --help (только запуск клиента)" $times

# Время внутри приложения — из журнала системы (строка на команду: «команда … → ok N мс»), без запуска клиента.
/usr/bin/log show --info --start "$started_at" --style compact --predicate 'subsystem == "cloud.kurilov.mynotion" AND category == "control"' > $out/control.log 2>&1
for command in page.get block.update; do
  python3 -I - $command $out/control.log <<'PY' | while read -r line; do note "$line"; done
import re, sys
command, path = sys.argv[1:]
values = sorted(int(m.group(1)) for m in (re.search(r"%s .*→ ok (\d+) мс" % re.escape(command), l) for l in open(path, errors="replace")) if m)
if values:
    n = len(values)
    print(f"внутри приложения {command}: {n} вызовов, p50 {values[(n + 1) // 2 - 1]} мс, p95 {values[-(-n * 95 // 100) - 1]} мс, максимум {values[-1]} мс")
else:
    print(f"внутри приложения {command}: в журнале строк нет")
PY
done

# Покой: процессор и память без команд.
sleep 10
cpu=$(top -l 5 -s 1 -pid $pid -stats cpu | awk '/^[0-9.]+$/ { last = $1 } END { print last + 0 }')
memory_after=$(footprint_mb $pid)
note "процессор в покое с открытым сокетом, база эталона 004: $cpu %"
note "память: до серии команд $memory_before МБ, через 10 с после 480 команд $memory_after МБ"
kill $pid; while kill -0 $pid 2>/dev/null; do sleep 0.2; done

failed=0
(( get_p95 <= 150.0 )) && note "✓ page get p95 ≤ 150 мс" || { note "✗ page get p95 больше 150 мс: $get_p95"; failed=1 }
(( update_p95 <= 150.0 )) && note "✓ block update p95 ≤ 150 мс" || { note "✗ block update p95 больше 150 мс: $update_p95"; failed=1 }
[[ $cpu == 0 || $cpu == 0.0 ]] && note "✓ покой: 0 % процессора" || { note "✗ покой: $cpu % процессора"; failed=1 }
exit $failed
