#!/usr/bin/env bash
set -uo pipefail

EXIT_OK=0
EXIT_TEST_FAILED=1
EXIT_USAGE=2
EXIT_PROVIDER_UNAVAILABLE=3

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${VIRTTEST_REPORT_DIR:-${SCRIPT_DIR}/reports}"
COMMON_DIR="${SCRIPT_DIR}/common"
PROVISION_DIR="${SCRIPT_DIR}/provision"

# shellcheck source=action_tests/common/test_framework.sh
source "${COMMON_DIR}/test_framework.sh"

SUPPORTED_ENVIRONMENTS=(pve incus docker lxd containerd podman qemu kubevirt)

# shellcheck source=action_tests/common/runtime_helpers.sh
source "${COMMON_DIR}/runtime_helpers.sh"

ENV_NAME=""
RUN_ID=""
RUNTIME_TMP_DIR=""
REPORT_FILE=""
RESULTS_FILE=""
PROMETHEUS_FILE=""
RESOURCE_FILE=""
TEST_FAILED=0
VIRTTEST_DRY_RUN="${VIRTTEST_DRY_RUN:-0}"
VIRTTEST_STEP_TIMEOUT_SECONDS="${VIRTTEST_STEP_TIMEOUT_SECONDS:-1800}"
VIRTTEST_PROVISION_TIMEOUT_SECONDS="${VIRTTEST_PROVISION_TIMEOUT_SECONDS:-1500}"
VIRTTEST_PRECHECK_TIMEOUT_SECONDS="${VIRTTEST_PRECHECK_TIMEOUT_SECONDS:-300}"
VIRTTEST_REMOTE_RETRIES="${VIRTTEST_REMOTE_RETRIES:-3}"
VIRTTEST_RETRY_DELAY_SECONDS="${VIRTTEST_RETRY_DELAY_SECONDS:-5}"
VIRTTEST_TIMEOUT_MINUTES="${VIRTTEST_TIMEOUT_MINUTES:-210}"
RUN_DEADLINE_EPOCH=0

SSH_KEY_FILE=""
HOST_META_FILE=""
REMOTE_LOG_FILE=""
API_COUNTER_FILE=""

SERVER_ID=""
SERVER_IP=""
SSH_USER="root"
SSH_PASSWORD=""
HOST_STARTED_EPOCH=0

RESOURCE_HASH=0
RESOURCE_SUFFIX=""
BASE_PORT=0
PORT_HIGH=0
PORT_FINAL=0
PVE_CT_ID=0
PVE_VM_ID=0
DOCKER_NAME=""
CONTAINERD_NAME=""
PODMAN_NAME=""
QEMU_NAME=""
KUBEVIRT_NAME=""
LXD_CT_NAME=""
LXD_VM_NAME=""
INCUS_CT_NAME=""
INCUS_VM_NAME=""

mark_failed() {
  TEST_FAILED=1
}

record_skip() {
  local check_name="$1"
  local message="$2"
  local out_file="${REPORT_DIR}/${ENV_NAME}-${check_name// /_}.log"
  : >"$out_file"
  report_append_row "$REPORT_FILE" "$check_name" "SKIP" "0" "$message"
  results_add "$RESULTS_FILE" "$ENV_NAME" "$check_name" "SKIP" "0" "$message"
  log_warn "$check_name skipped: $message"
}

record_warn() {
  local check_name="$1"
  local duration="$2"
  local message="$3"
  report_append_row "$REPORT_FILE" "$check_name" "WARN" "$duration" "$message"
  results_add "$RESULTS_FILE" "$ENV_NAME" "$check_name" "WARN" "$duration" "$message"
  log_warn "$check_name warning: $message"
}

require_local_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    log_error "missing local command: $name"
    exit "$EXIT_USAGE"
  fi
}

has_ssh_key_material() {
  [[ -n "${LIGHTNODE_PRIVATE_KEY:-}" || -n "${LIGHTNODE_SSH_PRIVATE_KEY:-}" ]]
}

check_local_prereqs() {
  require_local_command curl
  require_local_command jq

  if [[ "$VIRTTEST_DRY_RUN" == "1" ]]; then
    return 0
  fi

  require_local_command ssh

  if ! has_ssh_key_material; then
    require_local_command sshpass
  elif [[ -n "${LIGHTNODE_PASSWORD:-}" ]] && ! command -v sshpass >/dev/null 2>&1; then
    log_warn "sshpass is not installed; password SSH fallback will be unavailable if key login fails"
  fi
}

check_required_config() {
  local missing=()
  if [[ -z "${LIGHTNODE_TOKEN:-}" ]]; then
    missing+=("LIGHTNODE_TOKEN")
  fi
  if [[ -z "${LIGHTNODE_PASSWORD:-}" ]]; then
    missing+=("LIGHTNODE_PASSWORD")
  fi
  if [[ "${#missing[@]}" -ne 0 ]]; then
    record_skip "configuration" "missing required env: ${missing[*]}"
    return 1
  fi
  return 0
}

export_provider_context() {
  export VIRTTEST_ENV_NAME="$ENV_NAME"
  export VIRTTEST_RUN_ID="$RUN_ID"
  export VIRTTEST_RESOURCE_SUFFIX="$RESOURCE_SUFFIX"
}

init_runtime_paths() {
  RUN_ID="$(date -u '+%Y%m%d-%H%M%S')-${RANDOM}"
  RUNTIME_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/virttest.XXXXXX")"
  chmod 700 "$RUNTIME_TMP_DIR"
  init_deadline
  compute_resource_identifiers
  REPORT_FILE="${REPORT_DIR}/${ENV_NAME}-report.md"
  RESULTS_FILE="${REPORT_DIR}/${ENV_NAME}-results.jsonl"
  PROMETHEUS_FILE="${REPORT_DIR}/${ENV_NAME}-metrics.prom"
  RESOURCE_FILE="${REPORT_DIR}/${ENV_NAME}-resources.json"
  SSH_KEY_FILE=""
  HOST_META_FILE="${RUNTIME_TMP_DIR}/host.json"
  API_COUNTER_FILE="${RUNTIME_TMP_DIR}/lightnode-api-calls.log"
  REMOTE_LOG_FILE="${REPORT_DIR}/${ENV_NAME}-remote.log"
}

write_ssh_key_file() {
  if has_ssh_key_material; then
    local old_umask
    old_umask="$(umask)"
    umask 077
    SSH_KEY_FILE="$(mktemp "${RUNTIME_TMP_DIR}/ssh-key.XXXXXX")"
    printf '%s\n' "${LIGHTNODE_PRIVATE_KEY:-${LIGHTNODE_SSH_PRIVATE_KEY:-}}" >"$SSH_KEY_FILE"
    chmod 600 "$SSH_KEY_FILE"
    umask "$old_umask"
  fi
}

remote_env_assignments() {
  printf 'VIRTTEST_ENV_NAME=%q VIRTTEST_RUN_ID=%q VIRTTEST_RESOURCE_SUFFIX=%q VIRTTEST_BASE_PORT=%q VIRTTEST_PORT_HIGH=%q VIRTTEST_PORT_FINAL=%q VIRTTEST_PVE_CT_ID=%q VIRTTEST_PVE_VM_ID=%q ' \
    "$ENV_NAME" "$RUN_ID" "$RESOURCE_SUFFIX" "$BASE_PORT" "$PORT_HIGH" "$PORT_FINAL" "$PVE_CT_ID" "$PVE_VM_ID"
}

remote_exec() {
  local cmd="$1"
  local remote_env ssh_rc
  if [[ -z "${SERVER_IP:-}" ]]; then
    echo "server IP is empty" >&2
    return 1
  fi

  remote_env="$(remote_env_assignments)"

  if [[ -n "${SSH_KEY_FILE:-}" && -f "$SSH_KEY_FILE" ]]; then
    # The command body is assembled from fixed test steps; dynamic values are exported as quoted variables.
    # shellcheck disable=SC2087
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 \
      -i "$SSH_KEY_FILE" "${SSH_USER}@${SERVER_IP}" "${remote_env} bash -se" <<EOF
set -euo pipefail
${cmd}
EOF
    then
      return 0
    else
      ssh_rc=$?
    fi
    if [[ "$ssh_rc" -ne 255 ]]; then
      return "$ssh_rc"
    fi
  fi

  if [[ -z "$SSH_PASSWORD" ]]; then
    return 1
  fi
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "sshpass is required for password SSH fallback" >&2
    return 1
  fi

  # The command body is assembled from fixed test steps; dynamic values are exported as quoted variables.
  # shellcheck disable=SC2087
  SSHPASS="${SSH_PASSWORD}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 \
    "${SSH_USER}@${SERVER_IP}" "${remote_env} bash -se" <<EOF
set -euo pipefail
${cmd}
EOF
}

local_check() {
  local check_name="$1"
  shift
  local out_file="${REPORT_DIR}/${ENV_NAME}-${check_name// /_}.log"
  local started ended duration timeout_seconds
  started=$(date +%s)
  timeout_seconds="$(remaining_timeout "$VIRTTEST_STEP_TIMEOUT_SECONDS")"
  if run_with_timeout "$timeout_seconds" "$@" >"$out_file" 2>&1; then
    ended=$(date +%s)
    duration=$((ended - started))
    report_append_row "$REPORT_FILE" "$check_name" "PASS" "$duration" "ok"
    results_add "$RESULTS_FILE" "$ENV_NAME" "$check_name" "PASS" "$duration" "ok"
    log_ok "$check_name"
    return 0
  fi
  ended=$(date +%s)
  duration=$((ended - started))
  report_append_row "$REPORT_FILE" "$check_name" "FAIL" "$duration" "failed, see $(basename "$out_file")"
  results_add "$RESULTS_FILE" "$ENV_NAME" "$check_name" "FAIL" "$duration" "failed, see $(basename "$out_file")"
  log_error "$check_name"
  mark_failed
  return 1
}

remote_check() {
  local check_name="$1"
  local cmd="$2"
  local out_file="${REPORT_DIR}/${ENV_NAME}-${check_name// /_}.log"
  local started ended duration timeout_seconds
  started=$(date +%s)
  timeout_seconds="$(remaining_timeout "$VIRTTEST_STEP_TIMEOUT_SECONDS")"
  if retry_command "$VIRTTEST_REMOTE_RETRIES" "$VIRTTEST_RETRY_DELAY_SECONDS" "$timeout_seconds" remote_exec "$cmd" >"$out_file" 2>&1; then
    ended=$(date +%s)
    duration=$((ended - started))
    report_append_row "$REPORT_FILE" "$check_name" "PASS" "$duration" "ok"
    results_add "$RESULTS_FILE" "$ENV_NAME" "$check_name" "PASS" "$duration" "ok"
    log_ok "$check_name"
    return 0
  fi
  ended=$(date +%s)
  duration=$((ended - started))
  report_append_row "$REPORT_FILE" "$check_name" "FAIL" "$duration" "failed, see $(basename "$out_file")"
  results_add "$RESULTS_FILE" "$ENV_NAME" "$check_name" "FAIL" "$duration" "failed, see $(basename "$out_file")"
  log_error "$check_name"
  mark_failed
  return 1
}

remote_cleanup_check() {
  local check_name="$1"
  local cmd="$2"
  local out_file="${REPORT_DIR}/${ENV_NAME}-${check_name// /_}.log"
  local started ended duration timeout_seconds
  started=$(date +%s)
  timeout_seconds="$(remaining_timeout "$VIRTTEST_STEP_TIMEOUT_SECONDS")"
  if retry_command "$VIRTTEST_REMOTE_RETRIES" "$VIRTTEST_RETRY_DELAY_SECONDS" "$timeout_seconds" remote_exec "$cmd" >"$out_file" 2>&1; then
    ended=$(date +%s)
    duration=$((ended - started))
    report_append_row "$REPORT_FILE" "$check_name" "PASS" "$duration" "ok"
    results_add "$RESULTS_FILE" "$ENV_NAME" "$check_name" "PASS" "$duration" "ok"
    log_ok "$check_name"
    return 0
  fi
  ended=$(date +%s)
  duration=$((ended - started))
  record_warn "$check_name" "$duration" "cleanup failed, see $(basename "$out_file")"
  return 0
}

remote_wait_check() {
  local check_name="$1"
  local cmd="$2"
  local timeout_seconds="${3:-300}"
  local delay_seconds="${4:-5}"
  local max_delay_seconds="${5:-30}"
  local out_file="${REPORT_DIR}/${ENV_NAME}-${check_name// /_}.log"
  local started ended duration elapsed=0 command_timeout

  started=$(date +%s)
  while [[ "$elapsed" -lt "$timeout_seconds" ]]; do
    command_timeout="$(remaining_timeout 60)"
    if run_with_timeout "$command_timeout" remote_exec "$cmd" >"$out_file" 2>&1; then
      ended=$(date +%s)
      duration=$((ended - started))
      report_append_row "$REPORT_FILE" "$check_name" "PASS" "$duration" "ok"
      results_add "$RESULTS_FILE" "$ENV_NAME" "$check_name" "PASS" "$duration" "ok"
      log_ok "$check_name"
      return 0
    fi
    sleep "$delay_seconds"
    elapsed=$((elapsed + delay_seconds))
    if [[ "$delay_seconds" -lt "$max_delay_seconds" ]]; then
      delay_seconds=$((delay_seconds * 2))
      if [[ "$delay_seconds" -gt "$max_delay_seconds" ]]; then
        delay_seconds="$max_delay_seconds"
      fi
    fi
  done

  ended=$(date +%s)
  duration=$((ended - started))
  report_append_row "$REPORT_FILE" "$check_name" "FAIL" "$duration" "timeout, see $(basename "$out_file")"
  results_add "$RESULTS_FILE" "$ENV_NAME" "$check_name" "FAIL" "$duration" "timeout, see $(basename "$out_file")"
  log_error "$check_name"
  mark_failed
  return 1
}

maybe_remote_check() {
  local step_ready="$1"
  local check_name="$2"
  local cmd="$3"
  local skip_reason="${4:-prerequisite failed}"

  if [[ "$step_ready" -ne 0 ]]; then
    remote_check "$check_name" "$cmd"
    return $?
  fi

  record_skip "$check_name" "$skip_reason"
  return 0
}

maybe_remote_wait_check() {
  local step_ready="$1"
  local check_name="$2"
  local cmd="$3"
  local timeout_seconds="${4:-300}"
  local delay_seconds="${5:-5}"
  local max_delay_seconds="${6:-30}"
  local skip_reason="${7:-prerequisite failed}"

  if [[ "$step_ready" -ne 0 ]]; then
    remote_wait_check "$check_name" "$cmd" "$timeout_seconds" "$delay_seconds" "$max_delay_seconds"
    return $?
  fi

  record_skip "$check_name" "$skip_reason"
  return 0
}

maybe_remote_cleanup_check() {
  local step_ready="$1"
  local check_name="$2"
  local cmd="$3"
  local skip_reason="${4:-prerequisite failed}"

  if [[ "$step_ready" -ne 0 ]]; then
    remote_cleanup_check "$check_name" "$cmd"
    return 0
  fi

  record_skip "$check_name" "$skip_reason"
  return 0
}

select_default_image() {
  if [[ -z "${LIGHTNODE_IMAGE_NAME:-}" ]]; then
    case "$ENV_NAME" in
      lxd|incus)
        export LIGHTNODE_IMAGE_NAME="ubuntu"
        ;;
      *)
        export LIGHTNODE_IMAGE_NAME="debian"
        ;;
    esac
  fi
}

preflight_provider() {
  local out_file="${REPORT_DIR}/${ENV_NAME}-preflight.log"
  local json_file="${REPORT_DIR}/${ENV_NAME}-preflight.json"
  local started ended duration preflight_rc timeout_seconds
  started=$(date +%s)
  select_default_image
  export_provider_context
  export VIRTTEST_LIGHTNODE_API_COUNTER_FILE="$API_COUNTER_FILE"
  timeout_seconds="$(remaining_timeout "$VIRTTEST_PRECHECK_TIMEOUT_SECONDS")"
  if run_with_timeout "$timeout_seconds" "${PROVISION_DIR}/lightnode.sh" validate >"$json_file" 2>"$out_file"; then
    ended=$(date +%s)
    duration=$((ended - started))
    report_append_row "$REPORT_FILE" "preflight_provider" "PASS" "$duration" "ok"
    results_add "$RESULTS_FILE" "$ENV_NAME" "preflight_provider" "PASS" "$duration" "ok"
    return 0
  fi

  preflight_rc=$?
  ended=$(date +%s)
  duration=$((ended - started))
  if [[ "$preflight_rc" -eq "$EXIT_PROVIDER_UNAVAILABLE" ]]; then
    report_append_row "$REPORT_FILE" "preflight_provider" "SKIP" "$duration" "provider unavailable, see $(basename "$out_file")"
    results_add "$RESULTS_FILE" "$ENV_NAME" "preflight_provider" "SKIP" "$duration" "provider unavailable, see $(basename "$out_file")"
    log_warn "preflight_provider skipped: provider unavailable"
    return "$EXIT_PROVIDER_UNAVAILABLE"
  fi
  report_append_row "$REPORT_FILE" "preflight_provider" "FAIL" "$duration" "failed, see $(basename "$out_file")"
  results_add "$RESULTS_FILE" "$ENV_NAME" "preflight_provider" "FAIL" "$duration" "failed, see $(basename "$out_file")"
  mark_failed
  return "$preflight_rc"
}

cleanup_stale_hosts() {
  local out_file="${REPORT_DIR}/${ENV_NAME}-cleanup-stale.log"
  local json_file="${REPORT_DIR}/${ENV_NAME}-cleanup-stale.json"
  local started ended duration timeout_seconds
  if [[ "${VIRTTEST_CLEANUP_STALE:-0}" != "1" ]]; then
    return 0
  fi
  started=$(date +%s)
  export_provider_context
  export VIRTTEST_LIGHTNODE_API_COUNTER_FILE="$API_COUNTER_FILE"
  timeout_seconds="$(remaining_timeout "$VIRTTEST_PRECHECK_TIMEOUT_SECONDS")"
  if run_with_timeout "$timeout_seconds" "${PROVISION_DIR}/lightnode.sh" cleanup-stale >"$json_file" 2>"$out_file"; then
    ended=$(date +%s)
    duration=$((ended - started))
    report_append_row "$REPORT_FILE" "cleanup_stale_hosts" "PASS" "$duration" "ok"
    results_add "$RESULTS_FILE" "$ENV_NAME" "cleanup_stale_hosts" "PASS" "$duration" "ok"
    return 0
  fi
  ended=$(date +%s)
  duration=$((ended - started))
  record_warn "cleanup_stale_hosts" "$duration" "stale cleanup failed, see $(basename "$out_file")"
  return 0
}

provision_host() {
  local out_file="${REPORT_DIR}/${ENV_NAME}-provision.log"
  local started ended duration provision_rc timeout_seconds
  started=$(date +%s)
  select_default_image
  export_provider_context
  export VIRTTEST_LIGHTNODE_API_COUNTER_FILE="$API_COUNTER_FILE"
  timeout_seconds="$(remaining_timeout "$VIRTTEST_PROVISION_TIMEOUT_SECONDS")"
  if run_with_timeout "$timeout_seconds" "${PROVISION_DIR}/lightnode.sh" create >"${HOST_META_FILE}" 2>"$out_file"; then
    ended=$(date +%s)
    duration=$((ended - started))
    report_append_row "$REPORT_FILE" "provision_host" "PASS" "$duration" "ok"
    results_add "$RESULTS_FILE" "$ENV_NAME" "provision_host" "PASS" "$duration" "ok"
  else
    provision_rc=$?
    ended=$(date +%s)
    duration=$((ended - started))
    if [[ "$provision_rc" -eq "$EXIT_PROVIDER_UNAVAILABLE" ]]; then
      report_append_row "$REPORT_FILE" "provision_host" "SKIP" "$duration" "provider unavailable, see $(basename "$out_file")"
      results_add "$RESULTS_FILE" "$ENV_NAME" "provision_host" "SKIP" "$duration" "provider unavailable, see $(basename "$out_file")"
      log_warn "provision_host skipped: provider unavailable"
      return "$EXIT_PROVIDER_UNAVAILABLE"
    fi
    report_append_row "$REPORT_FILE" "provision_host" "FAIL" "$duration" "failed, see $(basename "$out_file")"
    results_add "$RESULTS_FILE" "$ENV_NAME" "provision_host" "FAIL" "$duration" "failed, see $(basename "$out_file")"
    mark_failed
    return "$provision_rc"
  fi

  SERVER_ID="$(jq -r '.server_id' "$HOST_META_FILE")"
  SERVER_IP="$(jq -r '.ipv4' "$HOST_META_FILE")"
  SSH_PASSWORD="$(jq -r '.password // empty' "$HOST_META_FILE")"
  SSH_USER="$(jq -r '.ssh_user // "root"' "$HOST_META_FILE")"

  if [[ -z "$SERVER_ID" || -z "$SERVER_IP" ]]; then
    echo "invalid host metadata from provisioner" >"$out_file"
    report_append_row "$REPORT_FILE" "provision_host_metadata" "FAIL" "0" "missing server id or public ip"
    results_add "$RESULTS_FILE" "$ENV_NAME" "provision_host_metadata" "FAIL" "0" "missing server id or public ip"
    mark_failed
    return 1
  fi

  log_info "host ready id=${SERVER_ID} ip=${SERVER_IP}"
  HOST_STARTED_EPOCH="$(date +%s)"
  return 0
}

wait_ssh() {
  local max_wait_seconds=900
  local elapsed=0
  local delay_seconds=2
  local max_delay_seconds=30

  while [[ "$elapsed" -lt "$max_wait_seconds" ]]; do
    if [[ -f "$SSH_KEY_FILE" ]]; then
      if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
        -i "$SSH_KEY_FILE" "${SSH_USER}@${SERVER_IP}" "echo ok" >/dev/null 2>&1; then
        return 0
      fi
    fi
    if [[ -n "$SSH_PASSWORD" ]] && command -v sshpass >/dev/null 2>&1; then
      if SSHPASS="${SSH_PASSWORD}" sshpass -e ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
        "${SSH_USER}@${SERVER_IP}" "echo ok" >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep "$delay_seconds"
    elapsed=$((elapsed + delay_seconds))
    if [[ "$delay_seconds" -lt "$max_delay_seconds" ]]; then
      delay_seconds=$((delay_seconds * 2))
      if [[ "$delay_seconds" -gt "$max_delay_seconds" ]]; then
        delay_seconds="$max_delay_seconds"
      fi
    fi
  done
  return 1
}

api_call_count() {
  if [[ -s "${API_COUNTER_FILE:-}" ]]; then
    wc -l <"$API_COUNTER_FILE" | tr -d ' '
  else
    printf '0\n'
  fi
}

write_resource_summary() {
  local cleanup_status="${1:-NOT_RUN}"
  local cleanup_message="${2:-}"
  local ended runtime api_calls hourly_cost estimated_cost
  ended="$(date +%s)"
  if [[ "$HOST_STARTED_EPOCH" -gt 0 ]]; then
    runtime=$((ended - HOST_STARTED_EPOCH))
  else
    runtime=0
  fi
  api_calls="$(api_call_count)"
  hourly_cost="${LIGHTNODE_HOURLY_COST_USD:-0}"
  if ! [[ "$hourly_cost" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    hourly_cost=0
  fi
  estimated_cost="$(awk -v seconds="$runtime" -v hourly="$hourly_cost" 'BEGIN { printf "%.6f", (seconds / 3600) * hourly }')"

  jq -cn \
    --arg environment "$ENV_NAME" \
    --arg platform "lightnode" \
    --arg server_id "${SERVER_ID:-}" \
    --arg server_ip "${SERVER_IP:-}" \
    --arg region "${LIGHTNODE_REGION:-}" \
    --arg zone "${LIGHTNODE_ZONE:-}" \
    --arg cleanup_status "$cleanup_status" \
    --arg cleanup_message "$cleanup_message" \
    --arg runtime "$runtime" \
    --arg api_calls "$api_calls" \
    --arg hourly_cost "$hourly_cost" \
    --arg estimated_cost "$estimated_cost" \
    --arg resource_suffix "$RESOURCE_SUFFIX" \
    '{
      environment:$environment,
      platform:$platform,
      server_id:$server_id,
      server_ip:$server_ip,
      region:$region,
      zone:$zone,
      resource_suffix:$resource_suffix,
      host_runtime_seconds:($runtime|tonumber),
      lightnode_api_calls:($api_calls|tonumber),
      hourly_cost_usd:($hourly_cost|tonumber),
      estimated_compute_cost_usd:($estimated_cost|tonumber),
      network_bytes_estimate:null,
      cleanup_status:$cleanup_status,
      cleanup_message:$cleanup_message
    }' >"$RESOURCE_FILE"

  if [[ -n "${PROMETHEUS_FILE:-}" ]]; then
    {
      printf 'virttest_host_runtime_seconds{environment="%s",platform="lightnode"} %s\n' "$(prometheus_escape_label "$ENV_NAME")" "$runtime"
      printf 'virttest_lightnode_api_calls_total{environment="%s"} %s\n' "$(prometheus_escape_label "$ENV_NAME")" "$api_calls"
      printf 'virttest_estimated_compute_cost_usd{environment="%s",platform="lightnode"} %s\n' "$(prometheus_escape_label "$ENV_NAME")" "$estimated_cost"
    } >>"$PROMETHEUS_FILE"
  fi
}

cleanup() {
  set +e
  local cleanup_status="NOT_NEEDED"
  local cleanup_message=""
  if [[ -n "${SERVER_ID:-}" ]]; then
    log_info "destroy host id=${SERVER_ID}"
    export_provider_context
    export VIRTTEST_LIGHTNODE_API_COUNTER_FILE="$API_COUNTER_FILE"
    if "${PROVISION_DIR}/lightnode.sh" destroy --server-id "$SERVER_ID" >/dev/null 2>"${REPORT_DIR}/${ENV_NAME}-destroy.log"; then
      cleanup_status="PASS"
      cleanup_message="host destroyed"
    else
      cleanup_status="WARN"
      cleanup_message="host destroy failed, see ${ENV_NAME}-destroy.log"
      record_warn "destroy_host" "0" "$cleanup_message"
    fi
  fi
  [[ -n "${SSH_KEY_FILE:-}" ]] && rm -f "$SSH_KEY_FILE"
  [[ -n "${HOST_META_FILE:-}" ]] && rm -f "$HOST_META_FILE"
  if [[ -n "${RESOURCE_FILE:-}" ]]; then
    write_resource_summary "$cleanup_status" "$cleanup_message"
  fi
  [[ -n "${RUNTIME_TMP_DIR:-}" ]] && rm -rf "$RUNTIME_TMP_DIR"
}

prepare_remote_repo() {
  # shellcheck disable=SC2016
  remote_exec '
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget git jq ca-certificates
cd /root
rm -rf -- "/root/${VIRTTEST_ENV_NAME}"
git clone --depth 1 "https://github.com/oneclickvirt/${VIRTTEST_ENV_NAME}.git" "/root/${VIRTTEST_ENV_NAME}"
cd "/root/${VIRTTEST_ENV_NAME}"
chmod -R +x . || true
' >>"$REMOTE_LOG_FILE" 2>&1
}

run_case_docker() {
  local install_ready=1
  local resource_ready=1

  if ! maybe_remote_check "$install_ready" "docker_install" "
cd /root/docker
CN=false WITHOUTCDN=TRUE bash scripts/dockerinstall.sh
"; then
    install_ready=0
    resource_ready=0
  fi
  if ! maybe_remote_check "$resource_ready" "docker_create_container" "
cd /root/docker
bash scripts/onedocker.sh ${DOCKER_NAME} 1 512 VtPass123 ${BASE_PORT} ${PORT_HIGH} ${PORT_FINAL} n debian 0
"; then resource_ready=0; fi
  if ! maybe_remote_wait_check "$resource_ready" "docker_wait_running" "docker inspect -f '{{.State.Running}}' ${DOCKER_NAME} | grep -Fx true"; then resource_ready=0; fi
  if ! maybe_remote_check "$resource_ready" "docker_delete_container" "docker rm -f ${DOCKER_NAME}"; then resource_ready=0; fi
  if ! maybe_remote_wait_check "$resource_ready" "docker_verify_deleted" "! docker ps -a --format '{{.Names}}' | grep -Fx ${DOCKER_NAME}" 180 5 20; then resource_ready=0; fi
  maybe_remote_cleanup_check "$install_ready" "docker_uninstall" "
cd /root/docker
CONFIRM=yes bash dockeruninstall.sh
"
}

run_case_containerd() {
  local install_ready=1
  local resource_ready=1

  if ! maybe_remote_check "$install_ready" "containerd_install" "
cd /root/containerd
WITHOUTCDN=TRUE bash containerdinstall.sh
"; then
    install_ready=0
    resource_ready=0
  fi
  if ! maybe_remote_check "$resource_ready" "containerd_create_container" "
cd /root/containerd
bash scripts/onecontainerd.sh ${CONTAINERD_NAME} 1 512 VtPass123 ${BASE_PORT} ${PORT_HIGH} ${PORT_FINAL} n debian 0
"; then resource_ready=0; fi
  if ! maybe_remote_wait_check "$resource_ready" "containerd_wait_running" "nerdctl inspect -f '{{.State.Status}}' ${CONTAINERD_NAME} | grep -Fx running"; then resource_ready=0; fi
  if ! maybe_remote_check "$resource_ready" "containerd_delete_container" "nerdctl rm -f ${CONTAINERD_NAME}"; then resource_ready=0; fi
  if ! maybe_remote_wait_check "$resource_ready" "containerd_verify_deleted" "! nerdctl ps -a | awk 'NR>1{print \$NF}' | grep -Fx ${CONTAINERD_NAME}" 180 5 20; then resource_ready=0; fi
  maybe_remote_cleanup_check "$install_ready" "containerd_uninstall" "
cd /root/containerd
CONFIRM_UNINSTALL=yes bash containerduninstall.sh
"
}

run_case_podman() {
  local install_ready=1
  local resource_ready=1

  if ! maybe_remote_check "$install_ready" "podman_install" "
cd /root/podman
WITHOUTCDN=TRUE bash podmaninstall.sh
"; then
    install_ready=0
    resource_ready=0
  fi
  if ! maybe_remote_check "$resource_ready" "podman_create_container" "
cd /root/podman
bash scripts/onepodman.sh ${PODMAN_NAME} 1 512 VtPass123 ${BASE_PORT} ${PORT_HIGH} ${PORT_FINAL} n debian 0
"; then resource_ready=0; fi
  if ! maybe_remote_wait_check "$resource_ready" "podman_wait_running" "podman inspect -f '{{.State.Running}}' ${PODMAN_NAME} | grep -Fx true"; then resource_ready=0; fi
  if ! maybe_remote_check "$resource_ready" "podman_delete_container" "podman rm -f ${PODMAN_NAME}"; then resource_ready=0; fi
  if ! maybe_remote_wait_check "$resource_ready" "podman_verify_deleted" "! podman ps -a --format '{{.Names}}' | grep -Fx ${PODMAN_NAME}" 180 5 20; then resource_ready=0; fi
  maybe_remote_cleanup_check "$install_ready" "podman_uninstall" "
cd /root/podman
FORCE_UNINSTALL=true bash podmanuninstall.sh
"
}

run_case_qemu() {
  local install_ready=1
  local resource_ready=1

  if ! maybe_remote_check "$install_ready" "qemu_install" "
cd /root/qemu
noninteractive=true bash qemuinstall.sh
"; then
    install_ready=0
    resource_ready=0
  fi
  if ! maybe_remote_check "$resource_ready" "qemu_create_vm" "
cd /root/qemu
bash scripts/oneqemu.sh ${QEMU_NAME} 1 1024 10 VtPass123 ${BASE_PORT} ${PORT_HIGH} ${PORT_FINAL} debian12
"; then resource_ready=0; fi
  if ! maybe_remote_wait_check "$resource_ready" "qemu_wait_running" "virsh domstate ${QEMU_NAME} | grep -Fx running"; then resource_ready=0; fi
  if ! maybe_remote_check "$resource_ready" "qemu_delete_vm" "
cd /root/qemu
QEMU_FORCE_DELETE=yes bash scripts/delete_qemu.sh ${QEMU_NAME} -y
"; then resource_ready=0; fi
  if ! maybe_remote_wait_check "$resource_ready" "qemu_verify_deleted" "! virsh list --all --name | grep -Fx ${QEMU_NAME}" 180 5 20; then resource_ready=0; fi
  maybe_remote_cleanup_check "$install_ready" "qemu_uninstall" "
cd /root/qemu
QEMU_FORCE_UNINSTALL=yes bash qemuuninstall.sh
"
}

run_case_kubevirt() {
  local install_ready=1
  local resource_ready=1

  if ! maybe_remote_check "$install_ready" "kubevirt_install" "
cd /root/kubevirt
bash kubevirtinstall.sh
"; then
    install_ready=0
    resource_ready=0
  fi
  if ! maybe_remote_check "$resource_ready" "kubevirt_create_vm" "
cd /root/kubevirt
bash scripts/onevm.sh ${KUBEVIRT_NAME} 1 1 10 VtPass123 ${BASE_PORT} ${PORT_HIGH} ${PORT_FINAL} ubuntu
"; then resource_ready=0; fi
  if ! maybe_remote_wait_check "$resource_ready" "kubevirt_wait_running" "kubectl get vmi -n kubevirt-vms ${KUBEVIRT_NAME} -o jsonpath='{.status.phase}' | grep -Fx Running" 600 10 30; then resource_ready=0; fi
  if ! maybe_remote_check "$resource_ready" "kubevirt_delete_vm" "
cd /root/kubevirt
AUTO_YES=y bash scripts/deletevm.sh ${KUBEVIRT_NAME} y
"; then resource_ready=0; fi
  if ! maybe_remote_wait_check "$resource_ready" "kubevirt_verify_deleted" "! kubectl get vm -n kubevirt-vms -o name | grep -Fx vm.kubevirt.io/${KUBEVIRT_NAME}" 180 5 20; then resource_ready=0; fi
  maybe_remote_cleanup_check "$install_ready" "kubevirt_uninstall" "
cd /root/kubevirt
AUTO_YES=y bash kubevirtuninstall.sh
"
}

run_case_lxd() {
  local install_ready=1
  local container_ready=1
  local vm_ready=1

  if ! maybe_remote_check "$install_ready" "lxd_install" "
cd /root/lxd
noninteractive=true CN=false WITHOUTCDN=TRUE bash scripts/lxdinstall.sh
"; then
    install_ready=0
    container_ready=0
    vm_ready=0
  fi
  if ! maybe_remote_check "$container_ready" "lxd_create_container" "
cd /root/lxd
bash scripts/buildct.sh ${LXD_CT_NAME} 1 256 3 ${BASE_PORT} 0 0 1024 1024 n debian12
"; then container_ready=0; fi
  if ! maybe_remote_wait_check "$container_ready" "lxd_wait_container_running" "lxc list --format csv -c n,s | awk -F, '\$1==\"${LXD_CT_NAME}\" && \$2==\"RUNNING\" {found=1} END {exit found ? 0 : 1}'"; then container_ready=0; fi
  if ! maybe_remote_check "$container_ready" "lxd_delete_container" "lxc delete --force ${LXD_CT_NAME}"; then container_ready=0; fi
  if ! maybe_remote_wait_check "$container_ready" "lxd_verify_container_deleted" "! lxc list --format csv -c n | grep -Fx ${LXD_CT_NAME}" 180 5 20; then container_ready=0; fi

  if ! maybe_remote_check "$vm_ready" "lxd_create_vm" "
cd /root/lxd
bash scripts/buildvm.sh ${LXD_VM_NAME} 1 512 8 $((BASE_PORT + 1)) 0 0 1024 1024 n debian12
"; then vm_ready=0; fi
  if ! maybe_remote_wait_check "$vm_ready" "lxd_wait_vm_running" "lxc list --format csv -c n,s | awk -F, '\$1==\"${LXD_VM_NAME}\" && \$2==\"RUNNING\" {found=1} END {exit found ? 0 : 1}'"; then vm_ready=0; fi
  if ! maybe_remote_check "$vm_ready" "lxd_delete_vm" "lxc delete --force ${LXD_VM_NAME}"; then vm_ready=0; fi
  if ! maybe_remote_wait_check "$vm_ready" "lxd_verify_vm_deleted" "! lxc list --format csv -c n | grep -Fx ${LXD_VM_NAME}" 180 5 20; then vm_ready=0; fi

  maybe_remote_cleanup_check "$install_ready" "lxd_uninstall" "
cd /root/lxd
FORCE=true bash scripts/lxduninstall.sh
"
}

run_case_incus() {
  local install_ready=1
  local container_ready=1
  local vm_ready=1

  if ! maybe_remote_check "$install_ready" "incus_install" "
cd /root/incus
noninteractive=true CN=false WITHOUTCDN=TRUE bash scripts/incus_install.sh
"; then
    install_ready=0
    container_ready=0
    vm_ready=0
  fi
  if ! maybe_remote_check "$container_ready" "incus_create_container" "
cd /root/incus
bash scripts/buildct.sh ${INCUS_CT_NAME} 1 256 3 ${BASE_PORT} 0 0 1024 1024 n debian12
"; then container_ready=0; fi
  if ! maybe_remote_wait_check "$container_ready" "incus_wait_container_running" "incus list --format csv -c n,s | awk -F, '\$1==\"${INCUS_CT_NAME}\" && \$2==\"RUNNING\" {found=1} END {exit found ? 0 : 1}'"; then container_ready=0; fi
  if ! maybe_remote_check "$container_ready" "incus_delete_container" "incus delete --force ${INCUS_CT_NAME}"; then container_ready=0; fi
  if ! maybe_remote_wait_check "$container_ready" "incus_verify_container_deleted" "! incus list --format csv -c n | grep -Fx ${INCUS_CT_NAME}" 180 5 20; then container_ready=0; fi

  if ! maybe_remote_check "$vm_ready" "incus_create_vm" "
cd /root/incus
bash scripts/buildvm.sh ${INCUS_VM_NAME} 1 512 8 $((BASE_PORT + 1)) 0 0 1024 1024 n debian12
"; then vm_ready=0; fi
  if ! maybe_remote_wait_check "$vm_ready" "incus_wait_vm_running" "incus list --format csv -c n,s | awk -F, '\$1==\"${INCUS_VM_NAME}\" && \$2==\"RUNNING\" {found=1} END {exit found ? 0 : 1}'"; then vm_ready=0; fi
  if ! maybe_remote_check "$vm_ready" "incus_delete_vm" "incus delete --force ${INCUS_VM_NAME}"; then vm_ready=0; fi
  if ! maybe_remote_wait_check "$vm_ready" "incus_verify_vm_deleted" "! incus list --format csv -c n | grep -Fx ${INCUS_VM_NAME}" 180 5 20; then vm_ready=0; fi

  maybe_remote_cleanup_check "$install_ready" "incus_uninstall" "
cd /root/incus
INCUS_FORCE_UNINSTALL=true bash scripts/uninstall_incus.sh
"
}

run_case_pve() {
  local install_ready=1
  local container_ready=1
  local vm_ready=1

  if ! maybe_remote_check "$install_ready" "pve_install" "
cd /root/pve
noninteractive=true FORCE_INSTALL=true CN=false WITHOUTCDN=TRUE PVE_HOSTNAME=pvetest bash scripts/install_pve.sh
"; then
    install_ready=0
    container_ready=0
    vm_ready=0
  fi

  if ! maybe_remote_check "$container_ready" "pve_create_container" "
cd /root/pve
bash scripts/buildct.sh ${PVE_CT_ID} VtPass123 1 512 5 ${BASE_PORT} 0 0 0 0 debian12 local n
"; then container_ready=0; fi
  if ! maybe_remote_wait_check "$container_ready" "pve_wait_container_running" "pct status ${PVE_CT_ID} | grep -Fx 'status: running'"; then container_ready=0; fi
  if ! maybe_remote_check "$container_ready" "pve_delete_container" "cd /root/pve && bash scripts/pve_delete.sh ${PVE_CT_ID}"; then container_ready=0; fi
  if ! maybe_remote_wait_check "$container_ready" "pve_verify_container_deleted" "! pct list | awk 'NR>1{print \$1}' | grep -Fx ${PVE_CT_ID}" 180 5 20; then container_ready=0; fi

  if ! maybe_remote_check "$vm_ready" "pve_create_vm" "
cd /root/pve
bash scripts/buildvm.sh ${PVE_VM_ID} vtuser VtPass123 1 1024 10 $((BASE_PORT + 1)) 0 0 0 0 debian12 local n
"; then vm_ready=0; fi
  if ! maybe_remote_wait_check "$vm_ready" "pve_wait_vm_running" "qm status ${PVE_VM_ID} | grep -Fx 'status: running'"; then vm_ready=0; fi
  if ! maybe_remote_check "$vm_ready" "pve_delete_vm" "cd /root/pve && bash scripts/pve_delete.sh ${PVE_VM_ID}"; then vm_ready=0; fi
  if ! maybe_remote_wait_check "$vm_ready" "pve_verify_vm_deleted" "! qm list | awk 'NR>1{print \$1}' | grep -Fx ${PVE_VM_ID}" 180 5 20; then vm_ready=0; fi

  maybe_remote_cleanup_check "$install_ready" "pve_uninstall" "
cd /root/pve
AUTO_CONFIRM=yes bash scripts/uninstall_pve.sh
"
}

run_case() {
  case "$ENV_NAME" in
    docker)
      run_case_docker
      ;;
    containerd)
      run_case_containerd
      ;;
    podman)
      run_case_podman
      ;;
    qemu)
      run_case_qemu
      ;;
    kubevirt)
      run_case_kubevirt
      ;;
    lxd)
      run_case_lxd
      ;;
    incus)
      run_case_incus
      ;;
    pve)
      run_case_pve
      ;;
  esac
}

main() {
  local provision_rc=0 preflight_rc=0
  parse_args "$@"
  if ! validate_environment_name "$ENV_NAME"; then
    usage >&2
    exit "$EXIT_USAGE"
  fi

  init_runtime_paths
  ensure_dir "$REPORT_DIR"
  report_init "$REPORT_FILE" "$ENV_NAME"
  results_init "$RESULTS_FILE"
  prometheus_init "$PROMETHEUS_FILE"
  trap cleanup EXIT

  require_local_command jq
  if ! check_required_config; then
    log_warn "test skipped for ${ENV_NAME}: required provider configuration is missing"
    exit "$EXIT_OK"
  fi
  check_local_prereqs

  preflight_provider
  preflight_rc=$?
  if [[ "$preflight_rc" -eq "$EXIT_PROVIDER_UNAVAILABLE" ]]; then
    log_warn "test skipped for ${ENV_NAME}: provider resources are unavailable"
    exit "$EXIT_OK"
  fi
  if [[ "$preflight_rc" -ne 0 ]]; then
    exit "$EXIT_TEST_FAILED"
  fi

  if [[ "$VIRTTEST_DRY_RUN" == "1" ]]; then
    report_append_row "$REPORT_FILE" "dry_run" "PASS" "0" "configuration and provider inventory validated without creating resources"
    results_add "$RESULTS_FILE" "$ENV_NAME" "dry_run" "PASS" "0" "configuration and provider inventory validated without creating resources"
    log_ok "dry_run"
    exit "$EXIT_OK"
  fi

  cleanup_stale_hosts
  write_ssh_key_file

  log_info "starting env test: ${ENV_NAME}"

  provision_host
  provision_rc=$?
  if [[ "$provision_rc" -eq "$EXIT_PROVIDER_UNAVAILABLE" ]]; then
    log_warn "test skipped for ${ENV_NAME}: provider resources are unavailable"
    exit "$EXIT_OK"
  fi
  if [[ "$provision_rc" -ne 0 ]]; then
    exit "$EXIT_TEST_FAILED"
  fi

  if ! local_check "wait_ssh" wait_ssh; then
    exit "$EXIT_TEST_FAILED"
  fi

  if ! local_check "prepare_remote_repo" prepare_remote_repo; then
    exit "$EXIT_TEST_FAILED"
  fi

  run_case

  if [[ "$TEST_FAILED" -ne 0 ]]; then
    log_error "test completed with failures for ${ENV_NAME}"
    exit "$EXIT_TEST_FAILED"
  fi

  log_ok "test completed for ${ENV_NAME}"
  exit "$EXIT_OK"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
