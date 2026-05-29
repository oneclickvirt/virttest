#!/usr/bin/env bash
set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }

now_utc() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

ensure_dir() {
  local d="$1"
  [[ -d "$d" ]] || mkdir -p "$d"
}

report_init() {
  local report_file="$1"
  local env_name="$2"
  cat >"$report_file" <<EOF
# Virttest Report: ${env_name}

- Start Time (UTC): $(now_utc)
- Environment: ${env_name}

| Check | Status | Duration(s) | Message |
|------|--------|-------------|---------|
EOF
}

report_append_row() {
  local report_file="$1"
  local check_name="$2"
  local status="$3"
  local duration="$4"
  local message="$5"
  message="${message//|/\\|}"
  echo "| ${check_name} | ${status} | ${duration} | ${message} |" >>"$report_file"
}

results_init() {
  local results_file="$1"
  : >"$results_file"
}

results_add() {
  local results_file="$1"
  local env_name="$2"
  local check_name="$3"
  local status="$4"
  local duration="$5"
  local message="$6"
  local ts
  ts="$(now_utc)"
  jq -cn \
    --arg ts "$ts" \
    --arg env "$env_name" \
    --arg check "$check_name" \
    --arg status "$status" \
    --arg duration "$duration" \
    --arg message "$message" \
    '{timestamp:$ts, environment:$env, check:$check, status:$status, duration_seconds:($duration|tonumber), message:$message}' >>"$results_file"
}

run_check() {
  local env_name="$1"
  local report_file="$2"
  local results_file="$3"
  local check_name="$4"
  local cmd="$5"
  local output_file="$6"

  local started ended duration
  started=$(date +%s)
  if bash -lc "$cmd" >"$output_file" 2>&1; then
    ended=$(date +%s)
    duration=$((ended - started))
    report_append_row "$report_file" "$check_name" "PASS" "$duration" "ok"
    results_add "$results_file" "$env_name" "$check_name" "PASS" "$duration" "ok"
    log_ok "$check_name"
    return 0
  fi

  ended=$(date +%s)
  duration=$((ended - started))
  local msg
  msg="failed, see $(basename "$output_file")"
  report_append_row "$report_file" "$check_name" "FAIL" "$duration" "$msg"
  results_add "$results_file" "$env_name" "$check_name" "FAIL" "$duration" "$msg"
  log_error "$check_name"
  return 1
}
