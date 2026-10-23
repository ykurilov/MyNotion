#!/bin/zsh
# На iMac внутри `imac-run --gui` (место «экран»): профиль превышений T085 — открытие вида, вкладки, запуск,
# место прокрутки. Не приёмочный замер: цифры бюджета дают сами тесты бюджета без sample.
#   perf-profile.zsh [open] [tabs] [launch] [fresh] [freshreg] [scroll] [scrollexp]   — без аргументов open tabs launch scroll
set -euo pipefail
source ${0:A:h}/lib.sh
require_toolchain
require_gui_session
out=$WORK/build/perf-profile
dd=build/imac-uitest-dd-release
rm -rf $out; mkdir -p $out
parts=($@)
(( $# )) || parts=(open tabs launch scroll)
context() { date; uptime; ps -axo pcpu,pid,comm | sort -nr | sed -n '1,10p'; }
context > $out/context.log

if (( ${parts[(I)open]} || ${parts[(I)tabs]} || ${parts[(I)launch]} || ${parts[(I)fresh]} || ${parts[(I)freshreg]} )); then
  xcodegen generate -q
  xcodebuild -scheme MyNotionPerformance -configuration Release -derivedDataPath $dd -jobs $JOBS build-for-testing -quiet > $out/build.log 2>&1
fi
app=$WORK/$dd/Build/Products/Release/MyNotion.app
reference=$TMPDIR/MyNotion-reference-library-v5/MyNotion.sqlite

# PID процесса, чей исполняемый файл — ровно наш (у других агентов свои копии).
own_pid() { pgrep -nf "^$1" || true; }

if (( ${parts[(I)open]} )); then
  print 'stage open' | tee -a $out/stages.log
  runs=($dd/Build/Products/*.xctestrun)
  TEST_RUNNER_MYNOTION_PERF_PROFILE=1 TEST_RUNNER_MYNOTION_PERF_PROFILE_READY=$out/open-ready.json \
    xcodebuild test-without-building -xctestrun $runs[1] -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
    -only-testing:PerformanceTests/DatabaseViewOpenProfileTests > $out/open-test.log 2>&1 &
  runner=$!
  for _ in {1..300}; do
    if [[ -f $out/open-ready.json ]]; then
      pid=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' $out/open-ready.json)
      sample $pid 10 1 -file $out/open-sample.txt > /dev/null 2>&1 || true
      break
    fi
    kill -0 $runner 2>/dev/null || break
    sleep 1
  done
  wait $runner || print "open test exit=$?" >> $out/stages.log
  grep -A30 'US3 OPEN PARTS' $out/open-test.log > $out/open-parts.txt || true
fi

if (( ${parts[(I)tabs]} )); then
  print 'stage tabs' | tee -a $out/stages.log
  mkdir -p $out/tabs
  cp -c $reference $out/tabs/MyNotion.sqlite
  open -n -g $app --args --database $out/tabs/MyNotion.sqlite --tabs-benchmark $out/tabs/report.json
  pid=""
  for _ in {1..50}; do pid=$(own_pid $app/Contents/MacOS/MyNotion); [[ -n $pid ]] && break; sleep 0.2; done
  # Весь прогон: подготовка (копии страниц) отсеивается при разборе по кадрам замера.
  [[ -n $pid ]] && sample $pid 400 1 -mayDie -file $out/tabs-sample.txt > /dev/null 2>&1 || true
  for _ in {1..600}; do [[ -f $out/tabs/report.json ]] && break; sleep 1; done
  sleep 2
  pkill -f "^$app/Contents/MacOS/MyNotion" || true
  rm -f $out/tabs/MyNotion.sqlite*
fi

if (( ${parts[(I)launch]} )); then
  print 'stage launch' | tee -a $out/stages.log
  mkdir -p $out/launch
  # Клон APFS — свой файл без страниц в кэше диска: так выглядит холодный эталон.
  launch_once() {
    local name=$1 db=$2 sampled=$3
    rm -f $out/launch/$name.json
    local requested=$(python3 -c 'import time;print(time.time())')
    open -n -g $app --args --database $db --launch-report $out/launch/$name.json
    if (( sampled )); then
      local pid=""
      for _ in {1..100}; do pid=$(own_pid $app/Contents/MacOS/MyNotion); [[ -n $pid ]] && break; sleep 0.02; done
      [[ -n $pid ]] && sample $pid 2 1 -mayDie -file $out/launch-$name-sample.txt > /dev/null 2>&1 || true
    fi
    for _ in {1..60}; do [[ -f $out/launch/$name.json ]] && break; sleep 0.25; done
    print -r -- "$name requested=$requested $(cat $out/launch/$name.json 2>/dev/null)" >> $out/launch/results.txt
    sleep 1
    pkill -f "^$app/Contents/MacOS/MyNotion" || true
    sleep 1
  }
  cp -c $reference $out/launch/cold1.sqlite
  launch_once cold1 $out/launch/cold1.sqlite 0
  launch_once warm1 $out/launch/cold1.sqlite 0
  launch_once warm2 $out/launch/cold1.sqlite 0
  cp -c $reference $out/launch/cold2.sqlite
  launch_once cold2 $out/launch/cold2.sqlite 1
  launch_once warm3 $out/launch/cold2.sqlite 1
  rm -f $out/launch/*.sqlite*
fi

if (( ${parts[(I)fresh]} || ${parts[(I)freshreg]} )); then
  # Первый запуск только что собранного приложения: копия бандла — новый файл, которого система ещё не запускала.
  print 'stage fresh' | tee -a $out/stages.log
  mkdir -p $out/fresh
  cat $reference > /dev/null
  fresh_once() {
    local name=$1 bundle=$2
    rm -f $out/fresh/$name.json
    local requested=$(python3 -c 'import time;print(time.time())')
    open -n -g $bundle --args --database $reference --launch-report $out/fresh/$name.json
    for _ in {1..120}; do [[ -f $out/fresh/$name.json ]] && break; sleep 0.25; done
    print -r -- "$name requested=$requested $(cat $out/fresh/$name.json 2>/dev/null)" >> $out/fresh/results.txt
    sleep 1
    pkill -f "^$bundle/Contents/MacOS/MyNotion" || true
    sleep 1
  }
  # freshreg: та же копия, но до первого запуска её регистрирует LaunchServices — так видно, его ли это цена.
  lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  kinds=()
  (( ${parts[(I)fresh]} )) && kinds+=(copy)
  (( ${parts[(I)freshreg]} )) && kinds+=(reg)
  for round in 1 2 3; do
    for kind in $kinds; do
      copy=$out/fresh/$kind$round/MyNotion.app
      mkdir -p ${copy:h}
      cp -R $app $copy
      [[ $kind == reg ]] && $lsregister -f $copy
      sleep 3
      fresh_once $kind$round-first $copy
      fresh_once $kind$round-second $copy
    done
  done
  fresh_once original $app
  du -sh $app $app/Contents/MacOS/MyNotion > $out/fresh/size.txt 2>&1 || true
  otool -L $app/Contents/MacOS/MyNotion >> $out/fresh/size.txt 2>&1 || true
  rm -rf $out/fresh/copy* $out/fresh/reg*
fi

if (( ${parts[(I)scroll]} )); then
  print 'stage scroll' | tee -a $out/stages.log
  (cd Packages/MyNotionKit && swift test --scratch-path $WORK/build/perf-swiftpm --jobs $JOBS --filter PageScrollPlaceTests) > $out/scroll-unit.log 2>&1 \
    || print "scroll unit exit=$?" >> $out/stages.log
fi
if (( ${parts[(I)scrollexp]} )); then
  # Опыт: место прокрутки без `withoutUpdatesOnScroll` (465bdee) — копия пакета, исходники ветки не меняются.
  print 'stage scrollexp' | tee -a $out/stages.log
  exp=$WORK/build/perf-scrollexp
  rm -rf $exp; mkdir -p $exp
  rsync -a --exclude .build Packages/ $exp/Packages/
  python3 - $exp/Packages/MyNotionKit/Sources/PageEditor/PageScrollPlace.swift <<'PY'
import re,sys
p=sys.argv[1]; s=open(p).read()
s=re.sub(r'blockViews\.withoutUpdatesOnScroll \{\n(.*?)\n(\s*)\}\n', lambda m: m.group(1)+'\n', s, flags=re.S)
open(p,'w').write(s)
PY
  grep -c withoutUpdatesOnScroll $exp/Packages/MyNotionKit/Sources/PageEditor/PageScrollPlace.swift >> $out/stages.log || true
  (cd $exp/Packages/MyNotionKit && swift test --scratch-path $WORK/build/perf-swiftpm-exp --jobs $JOBS --filter PageScrollPlaceTests) > $out/scrollexp-unit.log 2>&1 \
    || print "scrollexp unit exit=$?" >> $out/stages.log
fi
context >> $out/context.log
print done >> $out/stages.log
