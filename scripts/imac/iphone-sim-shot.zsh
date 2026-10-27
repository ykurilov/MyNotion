#!/bin/zsh
# Запуск MyNotionPhone в симуляторе iPhone 17 Pro (iOS 26.5) на iMac и снимок экрана в build/iphone-shot.png.
# Приложение — из сборки scripts/imac/iphone-build.zsh.
set -euo pipefail
source ${0:A:h}/lib.sh

APP=$WORK/build/iphone/Build/Products/Debug-iphonesimulator/MyNotion.app
[[ -d $APP ]] || fail "Нет сборки $APP: сначала scripts/imac/iphone-build.zsh"
DEVICE=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if runtime.endswith("iOS-26-5"):
        print(next(d["udid"] for d in devices if d["name"] == "iPhone 17 Pro")); break')
xcrun simctl boot $DEVICE 2>/dev/null || true
xcrun simctl bootstatus $DEVICE -b >/dev/null
xcrun simctl install $DEVICE $APP
xcrun simctl launch --terminate-running-process $DEVICE cloud.kurilov.mynotion.ios
sleep 4
xcrun simctl io $DEVICE screenshot $WORK/build/iphone-shot.png
print -- "[MyNotion/iMac] iPhone: снимок build/iphone-shot.png ($DEVICE)"
