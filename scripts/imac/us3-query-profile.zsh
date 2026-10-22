#!/bin/zsh
# Без GUI: только build и выбранный XCTest с SQL/группировкой, без NSWindow/запуска приложения.
set -euo pipefail
no_sample=0
[[ ${1:-} == --no-sample ]] && no_sample=1
[[ -e build ]] || ln -s .imac-runner-us3-build build
source ${0:A:h}/lib.sh
require_toolchain
out=$WORK/build/us3-query-profile
dd=$WORK/build/imac-uitest-dd-release
mkdir -p $out
rm -f $out/ready.json $out/sample.txt $out/sample-command.log $out/test.log
date > $out/context.log
uptime >> $out/context.log
ps -axo pcpu,pid,comm | sort -nr | sed -n '1,15p' >> $out/context.log
xcodegen generate -q
xcodebuild -scheme MyNotionPerformance -configuration Release -derivedDataPath $dd -jobs 4 build-for-testing -quiet > $out/build.log 2>&1
runs=($dd/Build/Products/*.xctestrun)
run=$runs[1]
cp $run $out/original.xctestrun
# Явная переменная только у диагностического теста; обычный полный набор его пропускает.
python3 - "$run" "$out/ready.json" <<'PY'
import plistlib,sys
path=sys.argv[1]
with open(path,'rb') as f: root=plistlib.load(f)
def visit(node):
    if isinstance(node,dict):
        if node.get('BlueprintName')=='PerformanceTests':
            node.setdefault('EnvironmentVariables',{}).update(MYNOTION_US3_QUERY_PROFILE='1', MYNOTION_US3_QUERY_PROFILE_READY=sys.argv[2])
        for key,value in list(node.items()):
            if key=='PerformanceTests' and isinstance(value,dict):
                value.setdefault('EnvironmentVariables',{}).update(MYNOTION_US3_QUERY_PROFILE='1', MYNOTION_US3_QUERY_PROFILE_READY=sys.argv[2])
            visit(value)
    elif isinstance(node,list):
        for item in node: visit(item)
visit(root)
with open(path,'wb') as f: plistlib.dump(root,f)
PY
xcodebuild test-without-building -xctestrun $run -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -only-testing:PerformanceTests/DatabaseViewQueryProfileTests > $out/test.log 2>&1 &
runner=$!
bundle=$dd/Build/Products/Release/PerformanceTests.xctest
sampled=0
for attempt in {1..120}; do
  target=""
  if [[ -f $out/ready.json ]]; then
    # PID от нашего теста и сверка реального пути bundle; поиск по отображению ps ненадёжен у XCTest.
    target=$(python3 - "$out/ready.json" "$bundle" <<'PYID'
import json,os,sys
with open(sys.argv[1]) as f: info=json.load(f)
assert os.path.realpath(info['bundle'])==os.path.realpath(sys.argv[2]), info['bundle']
print(int(info['pid']))
PYID
)
  fi
  if [[ -n $target ]]; then
    print -r -- "sample own xctest=$target bundle=$bundle" >> $out/context.log
    date >> $out/context.log
    uptime >> $out/context.log
    ps -axo pcpu,pid,comm | sort -nr | sed -n '1,15p' >> $out/context.log
    if (( !no_sample )); then
      sample $target 10 1 -file $out/sample.txt > $out/sample-command.log 2>&1 && sampled=1 || true
    fi
    break
  fi
  kill -0 $runner 2>/dev/null || break
  sleep 1
done
rc=0
wait $runner || rc=$?
cp $out/original.xctestrun $run
print -r -- "sampled=$sampled no_sample=$no_sample test_exit=$rc" | tee -a $out/context.log
cat $out/test.log
(( sampled || no_sample )) || exit 3
exit $rc
