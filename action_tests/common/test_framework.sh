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

prometheus_escape_label() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/ }"
  printf '%s' "$value"
}

prometheus_init() {
  local prometheus_file="$1"
  cat >"$prometheus_file" <<'EOF'
# HELP virttest_check_status Check status encoded as 1 for the emitted status label.
# TYPE virttest_check_status gauge
# HELP virttest_check_duration_seconds Check duration in seconds.
# TYPE virttest_check_duration_seconds gauge
EOF
}

prometheus_add() {
  local prometheus_file="$1"
  local env_name="$2"
  local check_name="$3"
  local status="$4"
  local duration="$5"
  local env_label check_label status_label
  [[ -n "${prometheus_file:-}" ]] || return 0
  env_label="$(prometheus_escape_label "$env_name")"
  check_label="$(prometheus_escape_label "$check_name")"
  status_label="$(prometheus_escape_label "$status")"
  {
    printf 'virttest_check_status{environment="%s",check="%s",status="%s"} 1\n' "$env_label" "$check_label" "$status_label"
    printf 'virttest_check_duration_seconds{environment="%s",check="%s"} %s\n' "$env_label" "$check_label" "$duration"
  } >>"$prometheus_file"
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
  prometheus_add "${PROMETHEUS_FILE:-}" "$env_name" "$check_name" "$status" "$duration"
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
