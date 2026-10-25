#!/bin/zsh
# Постоянная подпись готового MyNotion.app сертификатом Developer ID этого Mac (сборки с iMac приходят ad-hoc).
#
#   scripts/sign-app.sh <MyNotion.app>
#   MYNOTION_SIGN_IDENTITY=<SHA-1 или имя> scripts/sign-app.sh <MyNotion.app>   # другой сертификат
#
# Требование подписи у всех сборок одно (команда и идентификатор), поэтому Связка ключей и разрешения macOS
# остаются за приложением после обновления. Нет сертификата — выход с кодом 3.
set -euo pipefail

app=${1:?Укажите MyNotion.app}
identity=${MYNOTION_SIGN_IDENTITY:-}
if [[ -z $identity ]]; then
  identity=$(security find-identity -p codesigning -v | awk -F'"' '/"Developer ID Application:/ {print $2; exit}')
fi
[[ -n $identity ]] || { print -u2 -- "На этом Mac нет сертификата Developer ID Application (security find-identity -p codesigning -v)"; exit 3; }

# Сначала вложенная команда, потом пакет: подпись пакета закрепляет подписи вложенного.
helper=$app/Contents/Helpers/mynotion
[[ -f $helper ]] && codesign --force --sign $identity --identifier cloud.kurilov.mynotion.cli --timestamp=none $helper
codesign --force --sign $identity --identifier cloud.kurilov.mynotion --timestamp=none $app
codesign --verify --strict --deep $app
print -- "Подпись: $identity"
codesign -d -r- $app 2>&1 | grep designated
