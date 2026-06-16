#!/usr/bin/env bash
set -euo pipefail

ENV_DIR="${1:-}"
KEEP_RUNS="${2:-7}"
KEEP_DAYS="${3:-0}"

if [[ -z "$ENV_DIR" ]]; then
  echo "usage: $0 <environment_report_dir> [keep_runs] [keep_days]" >&2
  exit 2
fi

if ! [[ "$KEEP_RUNS" =~ ^[0-9]+$ ]] || [[ "$KEEP_RUNS" -lt 1 ]]; then
  KEEP_RUNS=7
fi

if ! [[ "$KEEP_DAYS" =~ ^[0-9]+$ ]]; then
  KEEP_DAYS=0
fi

run_epoch() {
  local run_name="$1"
  if [[ ! "$run_name" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
    return 1
  fi

  local y="${run_name:0:4}"
  local mo="${run_name:4:2}"
  local d="${run_name:6:2}"
  local h="${run_name:9:2}"
  local mi="${run_name:11:2}"
  local s="${run_name:13:2}"

  if date -u -d "${y}-${mo}-${d} ${h}:${mi}:${s} UTC" +%s >/dev/null 2>&1; then
    date -u -d "${y}-${mo}-${d} ${h}:${mi}:${s} UTC" +%s
    return 0
  fi

  date -u -j -f "%Y%m%d-%H%M%S" "$run_name" +%s 2>/dev/null
}

[[ -d "$ENV_DIR" ]] || exit 0

now_epoch="$(date -u +%s)"
keep_seconds=$((KEEP_DAYS * 86400))
index=0

while IFS= read -r run_dir; do
  index=$((index + 1))
  remove=0

  if [[ "$index" -gt "$KEEP_RUNS" ]]; then
    remove=1
  fi

  if [[ "$KEEP_DAYS" -gt 0 ]]; then
    run_name="$(basename "$run_dir")"
    if run_ts="$(run_epoch "$run_name")"; then
      if [[ $((now_epoch - run_ts)) -gt "$keep_seconds" ]]; then
        remove=1
      fi
    fi
  fi

  if [[ "$remove" -eq 1 ]]; then
    rm -rf -- "$run_dir"
  fi
done < <(find "$ENV_DIR" -mindepth 1 -maxdepth 1 -type d | sort -r)
