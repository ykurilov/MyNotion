#!/bin/zsh
# Установка команды `mynotion` и скилла агентов (research R14).
#
#   scripts/install-cli.sh                       # Release с iMac → подпись Developer ID → /Applications, ссылка, скилл
#   scripts/install-cli.sh --app <MyNotion.app>  # готовая сборка вместо сборки на iMac
#   scripts/install-cli.sh --target <папка>      # куда положить приложение (на iMac: ~/Applications)
#   scripts/install-cli.sh --skip-app            # приложение не трогать: ссылка и скилл (ссылка ждёт сборку 005)
#
# Приложение копируется, только если оно не запущено: иначе сообщение и выход без изменений.
# Прежние приложение и скилл уходят в Корзину, только когда новые уже встали на место.
set -euo pipefail

REPO=${0:A:h:h}
cd $REPO
target=/Applications app= skip_app=0
while (( $# )); do
  case $1 in
    --target) target=${2:a}; shift 2;;
    --app) app=${2:a}; shift 2;;
    --skip-app) skip_app=1; shift;;
    *) sed -n '2,10p' $0; exit 2;;
  esac
done

# В Корзину: прежнюю версию ещё можно вернуть. Без `trash` (macOS до 15) — стереть.
discard() {
  if (( $+commands[trash] )); then trash $1; else rm -rf $1; fi
}

# Поставить $1 на место $2. Прежнее — в резерв рядом; не встало новое — резерв возвращается.
replace() {
  local new=$1 installed=$2 reserve=$2.old
  [[ ! -e $reserve ]] || discard $reserve || true
  [[ ! -e $reserve ]] || { print -u2 -- "Не удалось убрать прошлый резерв $reserve — ничего не изменено"; return 1; }
  if [[ -e $installed ]] && ! mv $installed $reserve; then
    print -u2 -- "Не удалось отложить $installed — ничего не изменено"
    return 1
  fi
  if ! mv $new $installed; then
    [[ ! -e $reserve ]] || mv $reserve $installed || true
    print -u2 -- "Не удалось поставить $installed — оставлена прежняя версия"
    return 1
  fi
  [[ ! -e $reserve ]] || discard $reserve || print -u2 -- "Внимание: прежняя версия осталась в $reserve"
}

installed=$target/MyNotion.app
helper=$installed/Contents/Helpers/mynotion

if (( ! skip_app )); then
  # Рабочее приложение не подменяется на ходу: правки в окнах и сокет команд принадлежат запущенному.
  if pgrep -x MyNotion >/dev/null 2>&1; then
    print -u2 -- "MyNotion запущен. Закройте его и повторите установку — ничего не изменено."
    exit 4
  fi
  if [[ -z $app ]]; then
    # Сборка на iMac (skill imac): основной Mac только получает готовый пакет.
    stage=$(mktemp -d /tmp/mynotion-install.XXXXXX)
    imac-run --no-fallback --no-setup --wait 1800 --fetch build/install/MyNotion.app --out $stage -- \
      'export PATH=$HOME/.local/bin:$PATH XCODE_XCCONFIG_FILE=$PWD/scripts/imac/adhoc-signing.xcconfig; xcodegen generate -q && xcodebuild -scheme MyNotion -configuration Release -derivedDataPath build/install-dd -jobs 4 build -quiet && rm -rf build/install && mkdir -p build/install && cp -R build/install-dd/Build/Products/Release/MyNotion.app build/install/'
    # openrsync кладёт итог под полным путём копии на iMac — ищем пакет, где бы он ни оказался.
    found=($stage/**/MyNotion.app(N/D))
    (( $#found )) || { print -u2 -- "Сборка с iMac не пришла (папка $stage)"; exit 1; }
    app=$found[1]
  fi
  [[ -x $app/Contents/Helpers/mynotion ]] || { print -u2 -- "В $app нет Contents/Helpers/mynotion"; exit 1; }
  mkdir -p $target
  rm -rf $installed.new
  cp -R $app $installed.new
  # Постоянная подпись сертификатом этого Mac: сборка с iMac приходит ad-hoc.
  # На Mac без сертификата (iMac) подпись остаётся ad-hoc.
  signed=0; $REPO/scripts/sign-app.sh $installed.new || signed=$?
  if (( signed == 3 )); then print -u2 -- "Внимание: подпись осталась ad-hoc"; elif (( signed )); then exit $signed; fi
  replace $installed.new $installed || exit 1
  print -- "Приложение: $installed"
fi

if [[ ! -x $helper ]]; then
  (( skip_app )) || { print -u2 -- "Нет команды $helper"; exit 1; }
  # Приложение ещё старое: ссылка заработает, когда его заменят сборкой 005.
  print -- "Внимание: в $installed пока нет Contents/Helpers/mynotion — ссылка заработает после обновления приложения"
fi
mkdir -p ~/.local/bin
ln -sfn $helper ~/.local/bin/mynotion
print -- "Команда: ~/.local/bin/mynotion → $helper"

# Скилл — настоящей папкой, как соседние: Claude видит его через ~/.claude/skills → ~/.agents/skills.
skill=~/.agents/skills/mynotion
mkdir -p ${skill:h}
rm -rf $skill.new
cp -R Tools/mynotion-skill $skill.new
replace $skill.new $skill || exit 1
print -- "Скилл: $skill"

# Codex читает ~/.agents/skills сам. Если на этом Mac он видит соседние скиллы только по ссылкам из своей папки —
# ссылка и для этого.
codex_skills=$HOME/.codex/skills agents_skills=${skill:h:A} by_link=0
for link in $codex_skills/*(N@); do if [[ ${link:A} == $agents_skills/* ]]; then by_link=1; fi; done
if [[ ! -e $codex_skills/mynotion ]] && (( by_link )); then
  ln -s $skill $codex_skills/mynotion
  print -- "Codex: $codex_skills/mynotion → $skill"
fi

doctor=~/.codex/scripts/skill-doctor.sh
if [[ -x $doctor ]]; then
  $doctor $skill
else
  print -- "skill-doctor.sh нет на этом Mac — проверка скилла пропущена"
fi
