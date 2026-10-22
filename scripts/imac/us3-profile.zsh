#!/bin/zsh
# Запускать в копии проекта НА iMac через scripts/imac/run-on-imac.sh lock.
# Диагностический прогон: sample влияет на время; его цифры не подтверждают бюджет.
set -euo pipefail
source ${0:A:h}/lib.sh
out=$WORK/build/us3-profile
mkdir -p $out
print -r -- "Диагностический профиль US3; временные показатели этого прогона не приёмочные."
date > $out/context.log
uptime >> $out/context.log
ps -axo pcpu,pid,comm | sort -nr | sed -n '1,15p' >> $out/context.log
zsh scripts/imac/on-imac.sh uitest --release -only-testing:PerformanceTests/DatabaseViewPerformanceTests > $out/run.log 2>&1 &
runner=$!
bundle=$WORK/build/imac-uitest-dd-release/Build/Products/Release/PerformanceTests.xctest
sampled=0
for attempt in {1..900}; do
  # Полный путь bundle ограничивает выбор нашим xctest, чужих исполнителей не трогаем.
  physical=$bundle
  [[ -d ${bundle:h} ]] && physical=$(cd ${bundle:h} && pwd -P)/${bundle:t}
  target=$(ps -axo pid=,command= | awk -v bundle="$bundle" -v physical="$physical" \
    '!found && (index($0, bundle) || index($0, physical)) && index($0, "/xctest") && !index($0, "awk") { print $1; found=1 }')
  if [[ -n $target ]] && grep -q 'Test Case.*testViewChangesSearchAndGroupedScrollWithinBudget.*started' build/imac-uitest/uitest.log 2>/dev/null; then
    print -r -- "sample target=$target bundle=$bundle" >> $out/context.log
    sample $target 10 1 -file $out/sample.txt > $out/sample-command.log 2>&1 && sampled=1 || true
    break
  fi
  kill -0 $runner 2>/dev/null || break
  sleep 1
done
rc=0
wait $runner || rc=$?
[[ -f build/imac-uitest/uitest.log ]] && cp build/imac-uitest/uitest.log $out/uitest.log
print -r -- "sampled=$sampled test_exit=$rc" | tee -a $out/context.log
cat $out/run.log
(( sampled )) || exit 3
exit $rc
