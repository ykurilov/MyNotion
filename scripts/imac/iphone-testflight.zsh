#!/bin/zsh
# Архив MyNotionPhone и выкладка в TestFlight — на iMac (внутри `imac-run`). Запускается из scripts/iphone-testflight.zsh:
# тот кладёт ключ App Store Connect в $ASC_SECRETS_DIR и убирает его после. Подпись — автоматическая, сертификаты и
# профили выдаёт App Store Connect по ключу. Итог — строка «[MyNotion/iMac] TestFlight: …».
set -euo pipefail
source ${0:A:h}/lib.sh
unset XCODE_XCCONFIG_FILE

secrets=${ASC_SECRETS_DIR:?нужен ASC_SECRETS_DIR}
source $secrets/asc.env
auth=(-allowProvisioningUpdates -authenticationKeyPath $secrets/AuthKey_$ASC_KEY_ID.p8
      -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID)

# Связка login на iMac по SSH закрыта — подпись из своей связки MyNotion (README → «iPhone» → TestFlight):
# сертификат Apple Distribution, пароль связки лежит рядом, права 600. Профиль «MyNotion iPhone App Store» — в
# ~/Library/Developer/Xcode/UserData/Provisioning Profiles.
release=$HOME/.config/mynotion-release
[[ -f $release/signing.keychain-db ]] || fail "TestFlight: на iMac нет связки $release/signing.keychain-db"
security unlock-keychain -p "$(<$release/keychain-password)" $release/signing.keychain-db

# Номер сборки растёт сам: время выкладки (README → «iPhone»).
build_number=$(date -u +%Y%m%d.%H%M)
archive=build/testflight/MyNotionPhone.xcarchive
rm -rf build/testflight

xcodegen generate -q
xcodebuild archive -scheme MyNotionPhone -configuration Release -destination 'generic/platform=iOS' \
  -archivePath $archive -derivedDataPath build/iphone-release -jobs $JOBS -quiet \
  CURRENT_PROJECT_VERSION=$build_number $auth || fail "TestFlight: архив не собрался"

# TESTFLIGHT_ARCHIVE_ONLY=1 — проверить подпись без выкладки.
[[ ${TESTFLIGHT_ARCHIVE_ONLY:-0} == 1 ]] && { print -- "[MyNotion/iMac] TestFlight: архив $build_number собран, не выкладывался"; exit 0 }

xcodebuild -exportArchive -archivePath $archive -exportOptionsPlist scripts/testflight/ExportOptions.plist \
  -exportPath build/testflight/export -quiet $auth || fail "TestFlight: выкладка не прошла"

print -- "[MyNotion/iMac] TestFlight: сборка $build_number выложена, App Store Connect её обрабатывает"
