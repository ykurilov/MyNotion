#!/bin/zsh
# Переход копии реальной базы на текущую схему в Release (T116): копия открывается приложением, сравниваются
# число страниц и блоков и отпечатки их текста до и после. Печатаются только числа и отпечатки — не содержимое.
# Синхронизация, общий доступ и сокет команд в этом запуске не стартуют (--window-snapshot → allowsSync = false):
# копия на сервер не уходит. Снимок окна показывает данные — его никто не смотрит и не забирает: папка копии
# (база, её backup-v*, снимок, launch.json, build.log) удаляется в конце при любом исходе.
#
#   scripts/imac/migration-copy-check.zsh <копия базы на iMac>   # отдельная папка в ~/work/ только под эту копию
set -uo pipefail

REPO=${0:A:h:h:h}

if [[ ${MN_ON_IMAC:-} != 1 ]]; then
  (( $# == 1 )) || { print -u2 "Нужен путь к копии базы на iMac"; exit 2; }
  cd $REPO
  exec imac-run --gui --no-fallback --no-setup --wait ${MYNOTION_IMAC_WAIT:-1800} \
    -- "export PATH=\$HOME/.local/bin:\$HOME/.local/node/bin:\$PATH; MN_ON_IMAC=1 zsh scripts/imac/migration-copy-check.zsh ${(q)1}"
fi

source ${0:A:h}/lib.sh
require_toolchain; require_gui_session
db=${1/#\~/$HOME}
[[ -f $db ]] || fail "Нет копии базы: $db"
dir=${db:h}
[[ $dir == $HOME/work/?* ]] || fail "Копия должна лежать в своей папке внутри ~/work: $dir"
trap 'rm -rf $dir; [[ -e $dir ]] && print "папка копии осталась: $dir" || print "папка копии удалена"' EXIT

fingerprint() {
  sqlite3 $db "SELECT identifier FROM grdb_migrations ORDER BY rowid DESC LIMIT 1" | tr '\n' ' '
  print -n "страниц $(sqlite3 $db 'SELECT count(*) FROM page'), блоков $(sqlite3 $db 'SELECT count(*) FROM block'); "
  print -n "текст страниц $(sqlite3 $db 'SELECT id, title, icon, parentId, trashedAt FROM page ORDER BY id' | shasum -a 256 | cut -c1-12), "
  print "текст блоков $(sqlite3 $db 'SELECT id, pageId, kind, text, isDeleted FROM block ORDER BY id' | shasum -a 256 | cut -c1-12)"
}

build_app Release build/migration-copy-dd > $dir/build.log 2>&1 || { grep -E "error:" $dir/build.log | tail -10; fail "Сборка Release не прошла"; }
before=$(fingerprint)
print "до:    $before"
rm -f $dir/launch.json $dir/window.png
open -W -n $APP --args --database $db --launch-report $dir/launch.json --window-snapshot $dir/window.png
after=$(fingerprint)
print "после: $after"
print "запуск: $(python3 -c 'import json,sys; print(round(json.load(open(sys.argv[1]))["launchSeconds"], 2))' $dir/launch.json 2>/dev/null || print нет) с"
print "копия до перехода: $(ls $dir | grep -c 'backup-v') файл(ов); снимок окна: $([[ -s $dir/window.png ]] && print есть || print нет)"
latest=$(grep -oE 'Step\(version: "v[0-9]+"' Packages/MyNotionKit/Sources/NotesCore/Storage/SchemaMigrations.swift | tail -1 | grep -oE 'v[0-9]+')
[[ ${before#* } == ${after#* } && ${after%% *} == $latest ]] && { print "ИТОГ: переход без потерь"; exit 0; }
print "ИТОГ: расхождение"; exit 1
