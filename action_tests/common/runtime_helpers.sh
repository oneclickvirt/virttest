#!/usr/bin/env bash
# shellcheck disable=SC2034
set -uo pipefail

supported_env_list() {
  local IFS="|"
  printf '%s' "${SUPPORTED_ENVIRONMENTS[*]}"
}

usage() {
  echo "usage: $0 [--dry-run] <$(supported_env_list)>"
}

is_supported_environment() {
  local env_name="$1"
  local env
  for env in "${SUPPORTED_ENVIRONMENTS[@]}"; do
    if [[ "$env" == "$env_name" ]]; then
      return 0
    fi
  done
  return 1
}

validate_environment_name() {
  local env_name="$1"
  if [[ ! "$env_name" =~ ^[a-z0-9_-]+$ ]]; then
    log_error "invalid environment name: ${env_name}"
    return 1
  fi
  if ! is_supported_environment "$env_name"; then
    log_error "unsupported environment: ${env_name}"
    return 1
  fi
}

parse_args() {
  local env_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        VIRTTEST_DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage
        exit "$EXIT_OK"
        ;;
      --)
        shift
        break
        ;;
      -*)
        log_error "unknown option: $1"
        usage >&2
        exit "$EXIT_USAGE"
        ;;
      *)
        if [[ -n "$env_arg" ]]; then
          log_error "unexpected argument: $1"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        env_arg="$1"
        shift
        ;;
    esac
  done

  if [[ $# -gt 0 ]]; then
    log_error "unexpected argument: $1"
    usage >&2
    exit "$EXIT_USAGE"
  fi

  ENV_NAME="${env_arg:-docker}"
}

init_deadline() {
  if [[ "$VIRTTEST_TIMEOUT_MINUTES" =~ ^[0-9]+$ ]] && [[ "$VIRTTEST_TIMEOUT_MINUTES" -gt 0 ]]; then
    RUN_DEADLINE_EPOCH=$(($(date +%s) + (VIRTTEST_TIMEOUT_MINUTES * 60) - 120))
  else
    RUN_DEADLINE_EPOCH=0
  fi
}

remaining_timeout() {
  local requested="$1"
  if ! [[ "$requested" =~ ^[0-9]+$ ]] || [[ "$requested" -lt 1 ]]; then
    requested=1
  fi
  if [[ "$RUN_DEADLINE_EPOCH" -le 0 ]]; then
    printf '%s\n' "$requested"
    return 0
  fi

  local now remaining
  now="$(date +%s)"
  remaining=$((RUN_DEADLINE_EPOCH - now))
  if [[ "$remaining" -lt 1 ]]; then
    printf '1\n'
  elif [[ "$remaining" -lt "$requested" ]]; then
    printf '%s\n' "$remaining"
  else
    printf '%s\n' "$requested"
  fi
}

run_with_timeout() {
  local seconds="$1"
  shift
  if ! [[ "$seconds" =~ ^[0-9]+$ ]] || [[ "$seconds" -lt 1 ]]; then
    "$@"
    return $?
  fi

  local timeout_flag cmd_pid watchdog_pid rc
  timeout_flag="$(mktemp "${RUNTIME_TMP_DIR:-${TMPDIR:-/tmp}}/virttest-timeout.XXXXXX")"
  rm -f "$timeout_flag"

  "$@" &
  cmd_pid=$!
  (
    sleep "$seconds"
    if kill -0 "$cmd_pid" >/dev/null 2>&1; then
      : >"$timeout_flag"
      kill "$cmd_pid" >/dev/null 2>&1 || true
      sleep 2
      kill -9 "$cmd_pid" >/dev/null 2>&1 || true
    fi
  ) &
  watchdog_pid=$!

  wait "$cmd_pid"
  rc=$?
  kill "$watchdog_pid" >/dev/null 2>&1 || true
  wait "$watchdog_pid" >/dev/null 2>&1 || true

  if [[ -f "$timeout_flag" ]]; then
    rm -f "$timeout_flag"
    return 124
  fi
  return "$rc"
}

retry_command() {
  local attempts="$1"
  local delay="$2"
  local timeout_seconds="$3"
  shift 3

  if ! [[ "$attempts" =~ ^[0-9]+$ ]] || [[ "$attempts" -lt 1 ]]; then
    attempts=1
  fi
  if ! [[ "$delay" =~ ^[0-9]+$ ]] || [[ "$delay" -lt 1 ]]; then
    delay=1
  fi

  local attempt rc=1
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if run_with_timeout "$timeout_seconds" "$@"; then
      return 0
    fi
    rc=$?
    echo "attempt ${attempt}/${attempts} failed with exit ${rc}" >&2
    if [[ "$attempt" -lt "$attempts" ]]; then
      sleep "$delay"
      if [[ "$delay" -lt 60 ]]; then
        delay=$((delay * 2))
        [[ "$delay" -le 60 ]] || delay=60
      fi
    fi
  done
  return "$rc"
}

compute_resource_identifiers() {
  local seed cksum_value
  seed="${ENV_NAME}-${RUN_ID}-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}-${RANDOM}"
  cksum_value="$(printf '%s' "$seed" | cksum | awk '{print $1}')"
  RESOURCE_HASH="$cksum_value"
  RESOURCE_SUFFIX="$(printf '%06d' $((RESOURCE_HASH % 1000000)))"
  BASE_PORT=$((25000 + (RESOURCE_HASH % 5000)))
  PORT_HIGH=$((BASE_PORT + 3975))
  PORT_FINAL=$((BASE_PORT + 4000))
  PVE_CT_ID=$((200 + (RESOURCE_HASH % 7000)))
  PVE_VM_ID=$((PVE_CT_ID + 10000))

  DOCKER_NAME="vt-dk-${RESOURCE_SUFFIX}"
  CONTAINERD_NAME="vt-ctd-${RESOURCE_SUFFIX}"
  PODMAN_NAME="vt-pod-${RESOURCE_SUFFIX}"
  QEMU_NAME="vtqemu${RESOURCE_SUFFIX}"
  KUBEVIRT_NAME="vtkv-${RESOURCE_SUFFIX}"
  LXD_CT_NAME="vtlxdct-${RESOURCE_SUFFIX}"
  LXD_VM_NAME="vtlxdvm-${RESOURCE_SUFFIX}"
  INCUS_CT_NAME="vtincusct-${RESOURCE_SUFFIX}"
  INCUS_VM_NAME="vtincusvm-${RESOURCE_SUFFIX}"
}
