#!/bin/zsh
# Примеры из Tools/mynotion-skill/references/pages.md — по порядку, на Release из cli-live-check (база по умолчанию, потом стирается).
# В той же серии на iMac: run-on-imac.sh lock -- 'zsh scripts/imac/cli-live-check.zsh; zsh scripts/imac/cli-pages-examples.zsh'
set -uo pipefail
source scripts/imac/lib.sh
out=$WORK/build/pages-examples; rm -rf $out; mkdir -p $out; cd $out
m=$WORK/build/cli-live/home/.local/bin/mynotion
[[ -x $m ]] || fail "нет $m: сначала cli-live-check"
support=$HOME/Library/Application\ Support/MyNotion
had=0; [[ -d $support ]] && had=1
export MYNOTION_AGENT=pages-examples
n=0
run() { (( n++ )); print -r -- "\$ $*" >> log.txt; eval "$@" > r$n.json 2>&1; rc=$?; print -r -- "→ код $rc: $(head -c 400 r$n.json)" >> log.txt; }
id_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["data"]["page"]["id"])' $1 }
printf '# Повестка\n\n- пункт\n\n<div>html</div>\n' > notes.md
printf 'ещё строка\n' > more.md
$m page create --title Проекты > /dev/null; $m page create --title Архив > /dev/null
$m page create --title "Шаблон недели" > /dev/null
tpl=$($m page create --title "Шаблон отчёта" --markdown - <<< 'из шаблона' | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["page"]["id"])')
# Шаблоном страницу делает окно; здесь — та же отметка напрямую в базе приложения.
db=$($m app status | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["database"])')
sqlite3 "$db" "UPDATE page SET isTemplate = 1 WHERE lower(id) = lower('$tpl')" 2>> log.txt
run '$m page create --parent Проекты --title "Встреча 24.10" --icon 🚀 --markdown notes.md'
meeting=$(id_of r$n.json)
run 'cat notes.md | $m page create --title Черновик --markdown -'
run '$m page create --parent Проекты --title Итоги --after "Проекты/Встреча 24.10"'
run '$m page create --parent Проекты --title "Отчёт" --template "Шаблон отчёта"'
run '$m page tree --depth 1'
run '$m page tree Проекты'
run '$m page get "Проекты/Встреча 24.10"'
run '$m page read "Проекты/Встреча 24.10"'
run '$m page read "Проекты/Встреча 24.10" --format json'
run '$m page read Проекты --with-children'
run '$m page write "Проекты/Встреча 24.10" --markdown notes.md'
run "echo '- [ ] позвонить' | \$m page append \"Проекты/Встреча 24.10\" --markdown -"
block=$($m page read $meeting --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["blocks"][0]["id"])')
run '$m page append "Проекты/Встреча 24.10" --markdown - --after $block < more.md'
run '$m page rename "Проекты/Встреча 24.10" --title "Встреча 24.10 — итоги"'
run '$m page move "Встреча 24.10 — итоги" --parent Архив --first'
run '$m page layout "Архив/Встреча 24.10 — итоги" --full-width on --small-text off'
run '$m page move "Архив/Встреча 24.10 — итоги" --root'
run '$m page duplicate "Шаблон недели"'
run '$m page move "Встреча 24.10 — итоги" --parent "Встреча 24.10 — итоги"'
run '$m page trash Черновик'
run '$m trash list'
run '$m page restore Черновик'
run '$m page trash Черновик'
run '$m trash delete Черновик'
run '$m trash delete Черновик --force'
run '$m page trash Итоги'
run '$m trash empty --force'
run '$m page read $meeting'
pid=$(pgrep -x MyNotion | head -1); [[ -n $pid ]] && kill $pid
sleep 2
(( had )) || rm -rf $support
cat log.txt
