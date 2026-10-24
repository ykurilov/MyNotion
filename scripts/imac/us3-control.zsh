#!/bin/zsh
# Только в собственной runner-копии iMac внутри run-on-imac.sh lock.
# Архив общей ветки подготовлен git archive; это каталог исходников, не новый checkout.
set -euo pipefail
source ${0:A:h}/lib.sh
root=$WORK
out=$root/build/us3-control-results-9b4b05d-vs-4eca0a2-$(date +%Y%m%d-%H%M%S)
control=$root/build/us3-control-source-9b4b05d
mkdir -p $out $control
print -r -- "$out" > $root/build/us3-control-current
[[ -f $root/.us3-control.tar ]] || fail 'Нет архива контрольной ревизии'
tar -xf $root/.us3-control.tar -C $control
# Обе ревизии используют один fail-fast harness; product исходники baseline остаются9b4b05d.
cp $root/scripts/imac/lib.sh $control/scripts/imac/lib.sh
cp $root/scripts/imac/on-imac.sh $control/scripts/imac/on-imac.sh
cp $root/.us3-control-revision $out/control-revision.txt
print -r -- "merged product 4eca0a2, common docs4961489" > $out/us3-revision.txt
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
failed=0
for variant in common us3; do
  cd $root
  [[ $variant == common ]] && cd $control
  mkdir -p $out/$variant
  [[ ! -d build/imac-uitest ]] || mv build/imac-uitest $out/$variant/previous-uitest
  context > $out/$variant/context-before.log
  rc=0
  zsh scripts/imac/on-imac.sh uitest --release \
    -only-testing:PerformanceTests/LaunchAndMemoryTests \
    -only-testing:PerformanceTests/TabsPerformanceTests \
    -only-testing:PerformanceTests/TypingAndNavigationTests > $out/$variant/run.log 2>&1 || rc=$?
  context > $out/$variant/context-after.log
  if [[ -f build/imac-uitest/uitest.log ]]; then
    cp build/imac-uitest/uitest.log $out/$variant/uitest.log
  else
    print 'Свежий result не создан, см. run.log' > $out/$variant/no-fresh-result.txt
  fi
  print -r -- "$variant exit=$rc" | tee -a $out/exit-codes.log
  (( rc == 0 )) || failed=1
done
exit $failed
