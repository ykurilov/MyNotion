#!/bin/zsh
# Лёгкая shell-регрессия установки, без сборки, /Applications и настоящего HOME: приложение, подпись, `mv` и `trash` подставные.
# Новое не встало на место — рабочее приложение остаётся; встало — старое уходит в Корзину, а не стирается до замены.
set -euo pipefail
repo=${0:A:h:h:h:h}
fixture=$(mktemp -d /tmp/mynotion-install.XXXXXX)
trap 'rm -rf "$fixture"' EXIT
mkdir -p $fixture/repo/scripts $fixture/repo/Tools/mynotion-skill $fixture/home $fixture/bin $fixture/Apps
cp $repo/scripts/install-cli.sh $fixture/repo/scripts/
print -l -- '#!/bin/zsh' 'exit 3' > $fixture/repo/scripts/sign-app.sh
print -l -- '---' 'name: mynotion' '---' > $fixture/repo/Tools/mynotion-skill/SKILL.md

make_app() {
  mkdir -p $1/Contents/Helpers
  print -l -- '#!/bin/zsh' "print $2" > $1/Contents/Helpers/mynotion
  chmod +x $1/Contents/Helpers/mynotion
  print -- $2 > $1/Contents/version
}
print -l -- '#!/bin/zsh' 'exit 1' > $fixture/bin/pgrep
print -l -- '#!/bin/zsh' 'print -l -- "$@" >> $TRASHED' '/bin/rm -rf -- "$@"' > $fixture/bin/trash
cat > $fixture/bin/mv <<'STUB'
#!/bin/zsh
if [[ -n ${FAIL_PLACE:-} && ${@[-2]} == *.app.new && ${@[-1]} == */MyNotion.app ]]; then print -u2 -- "mv: нет места"; exit 1; fi
exec /bin/mv "$@"
STUB
chmod +x $fixture/repo/scripts/sign-app.sh $fixture/bin/*

install_app() {
  HOME=$fixture/home PATH=$fixture/bin:$PATH TRASHED=$fixture/trashed \
    zsh $fixture/repo/scripts/install-cli.sh --target $fixture/Apps --app $fixture/New.app >$fixture/log 2>&1
}
fail() { print -u2 -- "FAIL: $1"; cat $fixture/log >&2; exit 1; }

make_app $fixture/Apps/MyNotion.app старое
make_app $fixture/New.app новое
FAIL_PLACE=1 install_app && fail "установка без нового приложения на месте отчиталась успехом"
[[ $(cat $fixture/Apps/MyNotion.app/Contents/version 2>/dev/null) == старое ]] || fail "новое не встало, а рабочее приложение пропало"

install_app || fail "обычная установка упала"
[[ $(cat $fixture/Apps/MyNotion.app/Contents/version) == новое ]] || fail "новое приложение не на месте"
[[ ! -e $fixture/Apps/MyNotion.app.old && ! -e $fixture/Apps/MyNotion.app.new ]] || fail "рядом с приложением остался резерв или черновик"
grep -q 'MyNotion.app.old$' $fixture/trashed 2>/dev/null || fail "старое приложение стёрто, а не убрано в Корзину"
print -- "install-keeps-app: ok"
