#!/bin/zsh
# Без GUI: только build и выбранный XCTest с SQL/группировкой, без NSWindow/запуска приложения.
set -euo pipefail
[[ -e build ]] || ln -s .imac-runner-us3-build build
source ${0:A:h}/lib.sh
require_toolchain
out=$WORK/build/us3-query-profile
dd=$WORK/build/imac-uitest-dd-release
mkdir -p $out
date > $out/context.log
uptime >> $out/context.log
ps -axo pcpu,pid,comm | sort -nr | sed -n '1,15p' >> $out/context.log
xcodegen generate -q
xcodebuild -scheme MyNotionPerformance -configuration Release -derivedDataPath $dd -jobs 4 build-for-testing -quiet > $out/build.log 2>&1
runs=($dd/Build/Products/*.xctestrun)
run=$runs[1]
cp $run $out/original.xctestrun
# Явная переменная только у диагностического теста; обычный полный набор его пропускает.
python3 - "$run" <<'PY'
import plistlib,sys
path=sys.argv[1]
with open(path,'rb') as f: root=plistlib.load(f)
def visit(node):
    if isinstance(node,dict):
        if node.get('BlueprintName')=='PerformanceTests':
            node.setdefault('EnvironmentVariables',{})['MYNOTION_US3_QUERY_PROFILE']='1'
        for key,value in list(node.items()):
            if key=='PerformanceTests' and isinstance(value,dict):
                value.setdefault('EnvironmentVariables',{})['MYNOTION_US3_QUERY_PROFILE']='1'
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
physical=$(cd ${bundle:h} && pwd -P)/${bundle:t}
sampled=0
for attempt in {1..120}; do
  target=$(ps -axo pid=,command= | awk -v bundle="$bundle" -v physical="$physical" \
    '!found && (index($0,bundle)||index($0,physical)) && index($0,"/usr/bin/xctest") && !index($0,"awk") {print $1; found=1}')
  if [[ -n $target ]] && grep -q 'US3 QUERY PROFILE READY' $out/test.log; then
    print -r -- "sample own xctest=$target bundle=$bundle" >> $out/context.log
    date >> $out/context.log
    uptime >> $out/context.log
    ps -axo pcpu,pid,comm | sort -nr | sed -n '1,15p' >> $out/context.log
    sample $target 10 1 -file $out/sample.txt > $out/sample-command.log 2>&1 && sampled=1 || true
    break
  fi
  kill -0 $runner 2>/dev/null || break
  sleep 1
done
rc=0
wait $runner || rc=$?
cp $out/original.xctestrun $run
print -r -- "sampled=$sampled test_exit=$rc" | tee -a $out/context.log
cat $out/test.log
(( sampled )) || exit 3
exit $rc
