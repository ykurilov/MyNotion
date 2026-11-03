#!/bin/zsh
# Живая проверка баз 004 на двух Mac (T111, quickstart.md «Живая проверка на двух Mac», шесть шагов).
# Два экземпляра MyNotion (Release) на iMac со своими базами и свой сервер из server/ этой копии кода — боевой
# сервер не трогается. Второй экземпляр — копия приложения со своим bundle id: у каждого свои секреты синхронизации.
# Правки и чтение — командой `mynotion` через сокет каждого экземпляра; «без связи» — сервер заморожен (SIGSTOP).
#
#   scripts/imac/db-sync-live-check.zsh [--out <папка на этом Mac>]
# Итоги: summary.txt (шаги, задержки), ответы команд *.json, снимки окон обоих Mac *.png.
set -uo pipefail

REPO=${0:A:h:h:h}

if [[ ${MN_ON_IMAC:-} != 1 ]]; then
  # Основной Mac: весь сценарий — одной серией на iMac под местом «экран».
  OUT=/tmp/mn-db-sync-live-$(date +%H%M%S)
  while (( $# )); do case $1 in --out) OUT=$2; shift 2;; *) shift;; esac; done
  cd $REPO; stage=$(mktemp -d /tmp/mynotion-imac.XXXXXX); rc=0
  imac-run --gui --no-fallback --no-setup --wait ${MYNOTION_IMAC_WAIT:-1800} --fetch build/db-sync-live --out $stage \
    -- 'export PATH=$HOME/.local/bin:$HOME/.local/node/bin:$PATH; MN_ON_IMAC=1 zsh scripts/imac/db-sync-live-check.zsh' || rc=$?
  src=($stage/build/db-sync-live(N/) $stage/**/build/db-sync-live(N/D))
  if (( $#src )); then rm -rf $OUT; mkdir -p ${OUT:h}; mv $src[1] $OUT; print -- "Итог: $OUT"; fi
  rm -rf $stage; exit $rc
fi

# Дальше — на iMac, в копии проекта.
zmodload zsh/datetime  # EPOCHREALTIME
source ${0:A:h}/lib.sh
require_toolchain; require_gui_session

out=$WORK/build/db-sync-live
rm -rf $out; mkdir -p $out
summary=$out/summary.txt
failed=0
note() { print -r -- "$*" | tee -a $summary; }
check() { if eval "$2"; then note "✓ $1"; else note "✗ $1"; failed=1; fi }

PORT=39124
LIVE=/tmp/mndb   # короткий путь: сокет длиннее 100 байт уходит в хэш-имя
pgrep -x MyNotion >/dev/null && fail "На iMac уже запущен MyNotion: два своих экземпляра не запустить."

# Завершаем только своё: сервер этого прогона и два экземпляра с базами из $LIVE.
server_pid=""
cleanup() {
  [[ -n $server_pid ]] && { kill -CONT $server_pid 2>/dev/null; kill $server_pid 2>/dev/null; }
  for who in a b; do
    local pid; pid=$(pgrep -f "$LIVE/$who/MyNotion.sqlite" | head -1)
    [[ -n $pid ]] && kill $pid 2>/dev/null
  done
  cp $LIVE/server.log $LIVE/mac-a.log $LIVE/mac-b.log $out/ 2>/dev/null
  forget_sync_secrets
}
trap cleanup EXIT INT TERM

# 1. Сервер на iMac.
(cd server && pnpm install --frozen-lockfile --silent && pnpm --silent build) > $out/server-build.log 2>&1 \
  || { tail -20 $out/server-build.log; fail "Сервер не собрался"; }
[[ -z $(lsof -tiTCP:$PORT -sTCP:LISTEN 2>/dev/null || true) ]] || fail "Порт $PORT занят: чужой сервер оставлен без изменений."
rm -rf $LIVE; mkdir -p $LIVE/a $LIVE/b
DATA_DIR=$LIVE/server PORT=$PORT node $WORK/server/dist/main.js > $LIVE/server.log 2>&1 &
server_pid=$!
for _ in {1..50}; do curl -sf http://127.0.0.1:$PORT/health >/dev/null 2>&1 && break; sleep 0.2; done
(cd server && DATA_DIR=$LIVE/server node dist/cli.js bootstrap --name 'Mac A' --token-only > $LIVE/token)
URL=http://127.0.0.1:$PORT

# 2. Release и его копия со своим bundle id — «второй Mac».
build_app Release build/db-sync-live-dd > $out/build.log 2>&1 || { tail -30 $out/build.log; fail "Сборка Release не прошла"; }
cp -R $APP $LIVE/MyNotionB.app
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier cloud.kurilov.mynotion.second' $LIVE/MyNotionB.app/Contents/Info.plist
codesign --force --deep -s - $LIVE/MyNotionB.app 2>/dev/null
cli=$APP/Contents/Helpers/mynotion

mn() { local who=$1; shift; $cli "$@" --socket $LIVE/$who/control.sock --no-launch --agent db-sync-live }
run() { local name=$1 who=$2; shift 2; mn $who "$@" > $out/$name.json 2> $out/$name.err; print $? > $out/$name.rc; }
py() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" $1 2>/dev/null }
ok() { [[ $(py $out/$1.json 'd["ok"]') == True ]] }
# Ждать условия не дольше $1 с; сколько ждали — в WAITED.
WAITED=0
wait_until() {
  local limit=$1 started=$EPOCHREALTIME; shift
  while true; do
    if eval "$1"; then WAITED=$(printf '%.1f' $(( EPOCHREALTIME - started ))); return 0; fi
    (( EPOCHREALTIME - started > limit )) && { WAITED=$(printf '%.1f' $(( EPOCHREALTIME - started ))); return 1; }
    sleep 0.2
  done
}
# Строки базы на обоих Mac одинаковые (по id: название и все значения, в том числе итоги формул и сводок).
rows_of() { mn $1 db rows "$2" --limit 500 ${3:+--view} ${3:-} > $out/rows-$1.json 2>/dev/null; }
same_rows() {
  rows_of a "$1" "${2:-}" && rows_of b "$1" "${2:-}" && python3 - $out/rows-a.json $out/rows-b.json <<'EOF'
import json, sys
def rows(path):
    d = json.load(open(path))
    if not d.get("ok"): sys.exit(1)
    return sorted(((r["id"], r["title"], json.dumps(r["values"], sort_keys=True, ensure_ascii=False))
                   for g in d["data"]["groups"] for r in g["rows"]))
a, b = rows(sys.argv[1]), rows(sys.argv[2])
sys.exit(0 if a and a == b else 1)
EOF
}
value() { python3 - $out/rows-$1.json "$2" "$3" <<'EOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except ValueError:
    sys.exit(0)
for g in (d.get("data") or {}).get("groups", []):
    for r in g["rows"]:
        if r["title"] == sys.argv[2]:
            v = r["values"].get(sys.argv[3])
            print(json.dumps(v, ensure_ascii=False, sort_keys=True) if not isinstance(v, str) else v)
EOF
}
synced() { [[ $(mn $1 sync status 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["status"])' 2>/dev/null) == ready ]]; }
freeze() { kill -STOP $server_pid; }
thaw() { kill -CONT $server_pid; mn a sync now >/dev/null 2>&1; mn b sync now >/dev/null 2>&1; }
desktop_shot() {
  local driver=$HOME/.local/bin/cua-driver shots=$HOME/work/db-sync-live-shots
  mkdir -p $shots
  open -g -a $HOME/Applications/CuaDriver.app
  for t in {1..20}; do $driver status > /dev/null 2>&1 && break; sleep 0.5; done
  $driver call get_desktop_state "{\"screenshot_out_file\": \"$shots/$1.png\"}" > /dev/null 2>&1 && mv $shots/$1.png $out/ \
    || note "снимок $1 не получился"
}

# 3. Два экземпляра: первый — токеном, второй — кодом первого.
open -g -n $APP --args --database $LIVE/a/MyNotion.sqlite --sync-server $URL --sync-device-name "Mac A" --sync-log $LIVE/mac-a.log \
  --sync-connect-token-file $LIVE/token --sync-write-join-code $LIVE/join-code
wait_until 60 "[[ -S $LIVE/a/control.sock && -s $LIVE/join-code ]]" || fail "Первый Mac не поднял сокет или не выдал код подключения"
open -g -n $LIVE/MyNotionB.app --args --database $LIVE/b/MyNotion.sqlite --sync-server $URL --sync-device-name "Mac B" \
  --sync-log $LIVE/mac-b.log --sync-join-code-file $LIVE/join-code
wait_until 60 "[[ -S $LIVE/b/control.sock ]]" || fail "Второй Mac не поднял сокет"
check "оба Mac подключены к своему серверу ($URL)" "wait_until 60 'synced a && synced b'"

H="Проверка 004"; T="$H/Задачи"; P="$H/Проекты"

# Шаг 1. Текст — для сравнения задержки; затем «Задачи» с выбором, статусом, датой, связью с «Проектами», формулой и сводкой.
print -r -- 'Текст для сравнения задержки' > $out/text.md
started=$EPOCHREALTIME
run text a page create --title "Текст 004" --markdown $out/text.md
check "шаг 1: текст дошёл до второго Mac" "wait_until 30 'mn b page read \"Текст 004\" 2>/dev/null | grep -q \"сравнения задержки\"'"
text_delay=$(printf '%.1f' $(( EPOCHREALTIME - started )))
run host a page create --title "$H"
run projects a db create --parent "$H" --title Проекты
run tasks a db create --parent "$H" --title Задачи
run p-status a db prop add "$T" --name Статус --type status
run o-status a db option add "$T" Статус Идёт --group inProgress
run p-select a db prop add "$T" --name Приоритет --type select
run p-date a db prop add "$T" --name Срок --type date
run p-hours a db prop add "$T" --name Часы --type number
run p-rel a db prop add "$T" --name Проект --type relation --config '{"target":"Проверка 004/Проекты","related":"Задачи"}'
run p-formula a db prop add "$T" --name Вдвое --type formula --config '{"formula":"prop(\"Часы\") * 2"}'
run p-id a db prop add "$T" --name ID --type uniqueId
run p-files a db prop add "$T" --name Файлы --type files
run p-rollup a db prop add "$P" --name "Сумма часов" --type rollup --config '{"relation":"Задачи","property":"Часы","calculation":"sum"}'
run r-home a db row add "$P" --values '{"Название":"Дом"}'
run r-work a db row add "$P" --values '{"Название":"Работа"}'
run r-call a db row add "$T" --values '{"Название":"Позвонить","Статус":"Идёт","Приоритет":"Срочно","Срок":"2026-11-10","Часы":2,"Проект":["Дом"]}'
run r-buy a db row add "$T" --values '{"Название":"Купить","Приоритет":"Потом","Срок":"2026-11-12","Часы":3,"Проект":["Дом"]}'
run r-report a db row add "$T" --values '{"Название":"Сдать отчёт","Статус":"Идёт","Срок":"2026-11-14","Часы":4,"Проект":["Работа"]}'
setup_ok=1
for name in host projects tasks p-status o-status p-select p-date p-hours p-rel p-formula p-id p-files p-rollup r-home r-work r-call r-buy r-report; do
  ok $name || { setup_ok=0; note "  не прошла команда $name: $(head -c 300 $out/$name.json $out/$name.err)"; }
done
check "шаг 1: база собрана на первом Mac" "(( setup_ok ))"
check "шаг 1: «Задачи» и «Проекты» на втором Mac такие же — значения, итоги формулы и сводки" \
  "wait_until 30 'same_rows \"$T\" && same_rows \"$P\"'"
db_delay=$WAITED
rows_of b "$P"
check "шаг 1: сводка «Сумма часов» у «Дома» на втором Mac — 5" "[[ \$(value b Дом 'Сумма часов') == *5* ]]"
rows_of b "$T"
check "шаг 1: формула «Вдвое» у «Сдать отчёт» на втором Mac — 8" "[[ \$(value b 'Сдать отчёт' Вдвое) == *8* ]]"
rows_of a "$T"
check "шаг 1: формула «Вдвое» у «Купить» на первом Mac — 6 (посчитана там, где строка добавлена)" "[[ \$(value a Купить Вдвое) == *6* ]]"
note "  задержка: текст $text_delay с; база — $db_delay с после последней правки"
check "шаг 1: база дошла не позже 10 с" "(( db_delay <= 10 ))"
run schema-a a db schema "$T"; run schema-b b db schema "$T"
check "шаг 1: схема «Задач» одинаковая" "python3 -c 'import json,sys; a,b=(json.load(open(p))[\"data\"] for p in sys.argv[1:]); sys.exit(0 if json.dumps(a,sort_keys=True)==json.dumps(b,sort_keys=True) else 1)' $out/schema-a.json $out/schema-b.json"

# Шаг 2. Одновременно разные ячейки одной строки (сервер заморожен — правки не знают друг о друге).
freeze
run cell-a a db cell set "$T" Позвонить Часы --value 5
run cell-b b db cell set "$T" Позвонить Приоритет --value '"Потом"'
thaw
both_cells() { same_rows "$T" && [[ $(value a Позвонить Часы) == (5|5.0) && $(value a Позвонить Приоритет) == Потом ]]; }
check "шаг 2: обе правки на месте на обоих Mac" "wait_until 30 both_cells"
note "  сошлось за $WAITED с после возврата связи"

# Шаг 3. Одновременно по варианту выбора и по связи с каждого Mac.
freeze
run opt-a a db option add "$T" Приоритет "С A"
run opt-b b db option add "$T" Приоритет "С B"
run link-a a db relation link "$T" Купить Проект --to Работа
run link-b b db relation link "$T" "Сдать отчёт" Проект --to Дом
thaw
options_both() {
  for who in a b; do
    mn $who db schema "$T" 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)["data"]
p=[p for p in d["properties"] if p["name"]=="Приоритет"][0]
names={o["name"] for o in p.get("options",[])}
sys.exit(0 if {"С A","С B"} <= names else 1)' || return 1
  done
}
check "шаг 3: оба варианта на обоих Mac" "wait_until 30 options_both"
home_id=$(py $out/r-home.json 'd["data"]["row"]["id"]'); work_id=$(py $out/r-work.json 'd["data"]["row"]["id"]')
both_links() {
  same_rows "$P" && same_rows "$T" || return 1
  [[ -n $home_id && -n $work_id && $(value b Купить Проект) == *$work_id* && $(value b 'Сдать отчёт' Проект) == *$home_id* ]]
}
check "шаг 3: обе связи на обоих Mac, сводки сошлись" "wait_until 30 both_links"
rows_of a "$P"
note "  «Сумма часов»: Дом $(value a Дом 'Сумма часов'), Работа $(value a Работа 'Сумма часов')"

# Шаг 4. Фильтр и группировка вида на первом Mac — тот же вид на втором.
run view-add a db view add "$T" --name "С приоритетом"
view=$(py $out/view-add.json 'd["data"]["view"]["id"]')
run view-a a db view update "$T" $view --filter '{"property":"Приоритет","operator":"isNotEmpty"}' --group '{"property":"Статус"}'
same_view() {
  mn a db view list "$T" > $out/views-a.json 2>/dev/null && mn b db view list "$T" > $out/views-b.json 2>/dev/null && python3 - $out/views-a.json $out/views-b.json $view <<'EOF'
import json, sys
a, b = (json.load(open(p))["data"]["views"] for p in sys.argv[1:3])
pick = lambda views: [(v["id"], json.dumps(v.get("filter"), sort_keys=True), json.dumps(v.get("group"), sort_keys=True)) for v in views]
mine = [v for v in a if v["id"] == sys.argv[3]]
sys.exit(0 if pick(a) == pick(b) and mine and mine[0].get("filter") and mine[0].get("group") else 1)
EOF
}
check "шаг 4: вид с фильтром и группировкой на втором Mac такой же" "ok view-a && wait_until 30 same_view"
note "  дошёл за $WAITED с"
check "шаг 4: строки вида по группам одинаковые" "wait_until 10 'same_rows \"$T\" $view'"
note "  группы второго Mac: $(py $out/rows-b.json '[ (g["key"], g["count"]) for g in d["data"]["groups"] ]')"

# Шаг 5. Без связи по строке на каждом Mac — после встречи номера ID разные.
freeze
run row5-a a db row add "$T" --values '{"Название":"С A без связи"}'
run row5-b b db row add "$T" --values '{"Название":"С B без связи"}'
rows_of a "$T"; id_a_before=$(value a "С A без связи" ID)
rows_of b "$T"; id_b_before=$(value b "С B без связи" ID)
thaw
check "шаг 5: обе строки на обоих Mac" "wait_until 30 'same_rows \"$T\" && [[ -n \$(value a \"С B без связи\" ID) ]]'"
id_a=$(value a "С A без связи" ID); id_b=$(value a "С B без связи" ID)
note "  ID без связи: A $id_a_before, B $id_b_before; после встречи: $id_a и $id_b"
check "шаг 5: номера ID разные и одинаковые на обоих Mac" "[[ -n \$id_a && \$id_a != \$id_b ]] && same_rows \"$T\""

# Шаг 6. Файл 20 МБ в ячейке «Файлы» на первом Mac: на втором сперва заглушка, затем файл.
head -c 20971520 /dev/urandom > $LIVE/big-file.bin
run attach a attachment add "$T" Позвонить Файлы --file $LIVE/big-file.bin
attachment=$(py $out/attach.json 'd["data"]["attachment"]["id"]')
started=$EPOCHREALTIME
check "шаг 6: файл в ячейке первого Mac" "ok attach && [[ -n \$attachment ]]"
check "шаг 6: ячейка «Файлы» на втором Mac ссылается на файл" "wait_until 30 'rows_of b \"$T\" && [[ \$(value b Позвонить Файлы) == *\$attachment* ]]'"
cell_delay=$(printf '%.1f' $(( EPOCHREALTIME - started )))
rm -f $LIVE/got.bin
mn b attachment get $attachment --to $LIVE/got.bin > $out/get-first.json 2>&1
placeholder=$(py $out/get-first.json 'd.get("error",{}).get("code","")')
check "шаг 6: файл скачан на второй Mac, содержимое то же" \
  "wait_until 120 'mn b attachment get $attachment --to $LIVE/got.bin > $out/get.json 2>&1 && [[ -s $LIVE/got.bin ]]' \
   && [[ \$(shasum -a 256 < $LIVE/big-file.bin) == \$(shasum -a 256 < $LIVE/got.bin) ]]"
file_delay=$(printf '%.1f' $(( EPOCHREALTIME - started )))
note "  ячейка — за $cell_delay с; первый ответ второго Mac: ${placeholder:-файл уже был}; файл целиком — за $file_delay с"

# Снимки: «Задачи» в окне каждого Mac.
for who in a b; do
  mn $who open "$T" --activate > $out/open-$who.json 2>&1
  sleep 2
  desktop_shot mac-$who
done

note ""
(( failed )) && note "ИТОГ: есть ✗" || note "ИТОГ: все шаги ✓"
exit $failed
