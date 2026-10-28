#!/bin/zsh
# Пакетные тесты MyNotionKit в нескольких дорожках.
#
# `swift test` гоняет тестовые модули строго по очереди: в среднем занято одно ядро.
# Здесь каждый модуль — отдельный процесс со своим главным потоком, и модули идут
# в MYNOTION_TEST_LANES дорожках (по умолчанию 4), от долгих к коротким.
# Сами тесты те же, запускает их тот же помощник, что и `swift test`.
#
#   zsh scripts/test-package.zsh                    # все модули
#   zsh scripts/test-package.zsh --filter Sync      # аргументы уходят каждому модулю
#   MYNOTION_PERF=1 zsh scripts/test-package.zsh --filter "Performance|FullScale"   # замеры скорости
#
# Логи модулей: Packages/MyNotionKit/.build/test-lanes/<Модуль>.log.
# Выход с ошибкой, если упал хоть один модуль.
set -u
setopt null_glob
zmodload zsh/parameter

root=${0:A:h:h}
cd "$root/Packages/MyNotionKit" || exit 1
lanes=${MYNOTION_TEST_LANES:-4}

swift build --build-tests -j "$lanes" || exit 1

bin=$(swift build --show-bin-path)
helper=${$(xcrun --find swift):h:h}/libexec/swift/pm/swiftpm-testing-helper
# Тестовый модуль ищет XCTest и Testing там же, где их находит `swift test`.
platform=$(xcode-select -p)/Platforms/MacOSX.platform/Developer
export DYLD_FRAMEWORK_PATH=$platform/Library/Frameworks
export DYLD_LIBRARY_PATH=$platform/usr/lib
# `swift test` поднимает лимит открытых файлов; по SSH он 256, и тестам синхронизации не хватает.
ulimit -n 10240
logs=.build/test-lanes
rm -rf "$logs" && mkdir -p "$logs"

# Долгие модули — первыми, чтобы в конце не ждать одного длинного.
heavy=(PageEditorTests ControlCommandsTests NotesCoreTests PageMarkdownTests DatabasesTests
  NotionImportTests SyncTests MarkdownExportTests PageVersionsTests AttachmentsTests)
suites=()
for name in $heavy; do [[ -d $bin/$name.xctest ]] && suites+=$name; done
for bundle in $bin/*.xctest; do
  name=${bundle:t:r}
  (( ${suites[(Ie)$name]} )) || suites+=$name
done

run_module() {
  local name=$1; shift
  local exe=$bin/$name.xctest/Contents/MacOS/$name
  local started=$SECONDS
  "$helper" --test-bundle-path "$exe" "$@" "$exe" --testing-library swift-testing >"$logs/$name.log" 2>&1
  local code=$?
  # 69 — в модуле не нашлось тестов (заготовка или фильтр); `swift test` это не считает падением.
  (( code == 69 )) && ! grep -q "✘" "$logs/$name.log" && code=0
  print -r -- "$code $name $(( SECONDS - started ))" >>"$logs/.results"
  return $code
}

typeset -F SECONDS
started=$SECONDS
for name in $suites; do
  while (( ${#jobstates} >= lanes )); do sleep 0.2; done
  run_module $name "$@" &
done
wait

failed=0
while read -r code name seconds; do
  if (( code != 0 )); then
    failed=1
    print -r -- "✘ $name (код $code) — лог $PWD/$logs/$name.log"
    grep -E "✘|error|Fatal|crash" "$logs/$name.log" | head -20
  fi
done <"$logs/.results"

tests=$(cat $logs/*.log | grep -Eo "Test run with [0-9]+ tests?" | awk '{s+=$4} END {print s+0}')
sort -k3 -rn "$logs/.results" | head -8 | awk '{printf "  %-28s %6.1f с\n", $2, $3}'
printf "Модулей: %d, тестов: %d, время: %.1f с, дорожек: %d\n" ${#suites} $tests $(( SECONDS - started )) $lanes
if (( failed )); then print "ИТОГ: есть падения"; exit 1; fi
print "ИТОГ: все зелёные"
