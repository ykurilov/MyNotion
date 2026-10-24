#!/usr/bin/env python3
"""Run inside run-on-imac.sh lock: preflight every window layer, then native cursor/hover tests."""
import argparse
import json
import pathlib
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--out', type=pathlib.Path, default=pathlib.Path.home() / 'work/shots/text-cursor-final')
parser.add_argument('--results', default='build/text-cursor-final')
parser.add_argument('--pointer-only', action='store_true', help='Rerun only the cursor test after the native hover test passed')
args = parser.parse_args()
args.out.mkdir(parents=True, exist_ok=True)
driver = str(pathlib.Path.home() / '.local/bin/cua-driver')
subprocess.run(['open', '-g', '-a', str(pathlib.Path.home() / 'Applications/CuaDriver.app')], check=True)
for _ in range(10):
    if subprocess.run([driver, 'status'], capture_output=True).returncode == 0:
        break
    time.sleep(1)

def call(tool, payload):
    result = subprocess.run([driver, 'call', tool, json.dumps(payload)], check=True, capture_output=True, text=True)
    return json.loads(result.stdout)

preflight = call('get_desktop_state', {'screenshot_out_file': str(args.out / 'preflight.png')})
(args.out / 'preflight.json').write_text(json.dumps(preflight))
windows = call('list_windows', {'on_screen_only': True})
(args.out / 'windows.json').write_text(json.dumps(windows, ensure_ascii=False))
# Cua's ordinary list excludes high-level TCC windows (DeepL's prompt used layer8).
jxa = "ObjC.import('CoreGraphics'); JSON.stringify(ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(17,0))))"
cg = subprocess.run(['/usr/bin/osascript', '-l', 'JavaScript', '-e', jxa], check=True, capture_output=True, text=True)
(args.out / 'cg-windows.json').write_text(cg.stdout)
if any(w.get('kCGWindowOwnerName') == 'UserNotificationCenter' for w in json.loads(cg.stdout)):
    sys.exit('Preflight blocked: onscreen UserNotificationCenter window; inspect PNG, no clicks performed')
if any(w.get('app_name') in ('SecurityAgent', 'CoreServicesUIAgent', 'DeepL') for w in windows['windows']):
    sys.exit('Preflight blocked: system permission window; inspect PNG, no clicks performed')
# Sync removes the build symlink, while this worktree's protected cache survives.
if not pathlib.Path('build').exists():
    pathlib.Path('build').symlink_to('.imac-runner-hover-build', target_is_directory=True)
assert pathlib.Path('build/text-cursor-build.exit').read_text().strip() == '0', 'Fresh build must succeed first'
selectors = '-only-testing:UITests/TextPointerCursorLiveTests'
if not args.pointer_only:
    selectors += ' -only-testing:UITests/HoverHandlesLiveTests'
command = ('source scripts/imac/lib.sh; xctest_run build/imac-uitest-dd/Build/Products "$1" '
           f'{selectors} '
           '-test-timeouts-enabled YES -default-test-execution-time-allowance 180')
result = subprocess.run(['zsh', '-c', command, '--', args.results])
(args.out / 'test.exit').write_text(str(result.returncode))
sys.exit(result.returncode)
