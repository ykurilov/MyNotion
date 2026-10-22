#!/bin/zsh
# Только в собственной runner-копии iMac внутри run-on-imac.sh lock.
# Архив общей ветки подготовлен git archive; это каталог исходников, не новый checkout.
set -euo pipefail
source ${0:A:h}/lib.sh
root=$WORK
out=$root/build/us3-control-results
control=$root/build/us3-control-source
mkdir -p $out $control
[[ -f $root/.us3-control.tar ]] || fail 'Нет архива контрольной ревизии'
tar -xf $root/.us3-control.tar -C $control
cp $root/.us3-control-revision $out/control-revision.txt
shasum -a 256 Packages/MyNotionKit/Sources/DatabaseViewBar/Panels/ViewPanels.swift \
  Packages/MyNotionKit/Sources/DatabaseViewBar/Panels/ViewSettingsPanel.swift \
  Packages/MyNotionKit/Sources/DatabaseViewBar/Panels/FilterPages.swift > $out/us3-source-sha256.txt
context() {
  date
  sw_vers
  xcodebuild -version
  uptime
  ps -axo pcpu,pid,comm | sort -nr | sed -n '1,15p'
  python3 - <<'PY'
import hashlib, os, tempfile
for folder in ['MyNotion-reference-library-v5', 'MyNotion-db004-sample-v3']:
    p=os.path.join(tempfile.gettempdir(),folder,'MyNotion.sqlite')
    if os.path.isfile(p):
        h=hashlib.sha256()
        with open(p,'rb') as f:
            for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
        print(folder, os.path.getsize(p), h.hexdigest())
    else: print(folder, 'missing')
PY
}
# Не изменяем эталон: штатные тесты берут его копию. Обе ревизии идут подряд в одном слоте.
for variant in common us3; do
  cd $root
  [[ $variant == common ]] && cd $control
  mkdir -p $out/$variant
  context > $out/$variant/context-before.log
  rc=0
  zsh scripts/imac/on-imac.sh uitest --release \
    -only-testing:PerformanceTests/LaunchAndMemoryTests \
    -only-testing:PerformanceTests/TabsPerformanceTests \
    -only-testing:PerformanceTests/TypingAndNavigationTests > $out/$variant/run.log 2>&1 || rc=$?
  context > $out/$variant/context-after.log
  cp build/imac-uitest/uitest.log $out/$variant/uitest.log
  print -r -- "$variant exit=$rc" | tee -a $out/exit-codes.log
done
