#!/bin/zsh
# Снимки демо редактора страницы (PhoneApp/EditorDemo.swift) в симуляторе iPhone 17 Pro (iOS 26.5) на iMac:
# build/editor-light.png, build/editor-dark.png, build/editor-keyboard.png. Приложение — из scripts/imac/iphone-build.zsh.
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

shot() { # тема, аргумент запуска, файл
  xcrun simctl ui $DEVICE appearance $1
  xcrun simctl launch --terminate-running-process $DEVICE cloud.kurilov.mynotion.ios $2
  sleep 5
  xcrun simctl io $DEVICE screenshot $WORK/build/$3
}
shot light --editor-demo editor-light.png
shot dark --editor-demo editor-dark.png
shot light --editor-demo-keyboard editor-keyboard.png
xcrun simctl ui $DEVICE appearance light
print -- "[MyNotion/iMac] iPhone: снимки редактора build/editor-{light,dark,keyboard}.png ($DEVICE)"
