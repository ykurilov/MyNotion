#!/bin/zsh
# Сборка под iPhone на iMac (внутри `imac-run`): модули данных пакета и приложение MyNotionPhone —
# под симулятор и под устройство (без подписи). Итог — строка «[MyNotion/iMac] iPhone: …».
set -euo pipefail
source ${0:A:h}/lib.sh
unset XCODE_XCCONFIG_FILE

# Модули, которые на iPhone общие с Mac (specs/007-iphone-app/plan-draft.md). Насквозь AppKit — только на Mac.
PHONE_MODULES=(NotesCore Sync Attachments Databases Formulas MarkdownExport NotionImport PageMarkdown Proofreading NotionAPI
               PageVersions Backlinks LinkPreview CodeHighlighting Navigation Reminders PageSharing PageSearch VisualStyle PageCover
               PhoneShell PhonePageEditor)
DD=$WORK/build/iphone
built=0

for destination in 'generic/platform=iOS Simulator' 'generic/platform=iOS'; do
  for module in $PHONE_MODULES; do
    (cd Packages/MyNotionKit && xcodebuild build -scheme $module -destination $destination -derivedDataPath $DD \
       -jobs $JOBS -quiet CODE_SIGNING_ALLOWED=NO) || fail "iPhone: модуль $module не собрался ($destination)"
    (( built += 1 ))
  done
done

xcodegen generate -q
xcodebuild build -scheme MyNotionPhone -destination 'generic/platform=iOS Simulator' -derivedDataPath $DD -jobs $JOBS -quiet
xcodebuild build -scheme MyNotionPhone -destination 'generic/platform=iOS' -derivedDataPath $DD -jobs $JOBS -quiet CODE_SIGNING_ALLOWED=NO
print -- "[MyNotion/iMac] iPhone: модулей собрано $built (симулятор и устройство), MyNotionPhone — симулятор и устройство"

# Тесты модулей данных под iPhone: собираются всегда, прогон — в iPhone 17 Pro на iOS 26.5 (IPHONE_RUN_TESTS=0 — без прогона).
xcodebuild build-for-testing -scheme MyNotionPhone -destination 'generic/platform=iOS Simulator' -derivedDataPath $DD -jobs $JOBS -quiet
print -- "[MyNotion/iMac] iPhone: тесты NotesCoreTests, SyncTests, PhoneShellTests и PhonePageEditorTests собраны"
if [[ ${IPHONE_RUN_TESTS:-1} == 1 ]]; then
  rm -rf build/iphone-tests.xcresult
  xcodebuild test-without-building -scheme MyNotionPhone -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -derivedDataPath $DD \
    -parallel-testing-worker-count 4 -resultBundlePath build/iphone-tests.xcresult 2>&1 | grep -E "Test run with|✘|error:|TEST (SUCCEEDED|FAILED)" || true
fi
