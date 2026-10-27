#!/bin/zsh
# Выкладка MyNotion для iPhone в TestFlight с основного Mac: ключ App Store Connect на время сборки уходит на iMac
# (только для этого прогона, права 600), сама сборка — scripts/imac/iphone-testflight.zsh через `imac-run`.
set -euo pipefail

project_root=${0:A:h:h}
env_file=${ASC_ENV_FILE:-$HOME/.codex/secrets/asc-api-DC5QSJ54MB.env}
source $env_file
remote_dir=.imac-runner/secrets/mynotion-testflight-$$

cleanup() { ssh imac "rm -rf ~/$remote_dir" }
trap cleanup EXIT

ssh imac "umask 077 && mkdir -p ~/$remote_dir"
scp -q $ASC_KEY_PATH imac:$remote_dir/AuthKey_$ASC_KEY_ID.p8
print -r -- "ASC_KEY_ID=$ASC_KEY_ID"$'\n'"ASC_ISSUER_ID=$ASC_ISSUER_ID" | ssh imac "umask 077 && cat > ~/$remote_dir/asc.env"

cd $project_root
imac-run --no-fallback --wait 1800 --no-setup -- \
  "TESTFLIGHT_ARCHIVE_ONLY=${TESTFLIGHT_ARCHIVE_ONLY:-0} ASC_SECRETS_DIR=\$HOME/$remote_dir zsh scripts/imac/iphone-testflight.zsh"
