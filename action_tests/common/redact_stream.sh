#!/usr/bin/env bash
set -euo pipefail

sed -E \
  -e 's/(LIGHTNODE_(TOKEN|PASSWORD|PRIVATE_KEY|SSH_PRIVATE_KEY|SSH_KEY_UUID)[=:])[^\ \"'\'';,]+/\1[REDACTED]/g' \
  -e 's/(x-open-token:[[:space:]]*)[^\ \"'\'';,]+/\1[REDACTED]/Ig' \
  -e 's/("(password|token|privateKey|sshKeyUUID)"[[:space:]]*:[[:space:]]*")[^"]+(")/\1[REDACTED]\3/Ig' \
  -e 's/((password|token|private_key|ssh_private_key)[[:space:]]*=[[:space:]]*)[^[:space:]]+/\1[REDACTED]/Ig'
