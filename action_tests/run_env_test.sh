#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${SCRIPT_DIR}/reports"
COMMON_DIR="${SCRIPT_DIR}/common"
PROVISION_DIR="${SCRIPT_DIR}/provision"

source "${COMMON_DIR}/test_framework.sh"

ENV_NAME="${1:-docker}"
RUN_ID="$(date -u '+%Y%m%d-%H%M%S')-${RANDOM}"
REPORT_FILE="${REPORT_DIR}/${ENV_NAME}-report.md"
RESULTS_FILE="${REPORT_DIR}/${ENV_NAME}-results.jsonl"
TEST_FAILED=0

ensure_dir "$REPORT_DIR"
report_init "$REPORT_FILE" "$ENV_NAME"
results_init "$RESULTS_FILE"

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

require_local_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    log_error "missing local command: $name"
    exit 2
  fi
}

check_local_prereqs() {
  require_local_command jq
  require_local_command ssh
  if [[ -n "${LIGHTNODE_PASSWORD:-}" ]]; then
    require_local_command sshpass
  fi
}

check_local_prereqs

SSH_KEY_FILE="/tmp/virttest-${RUN_ID}.key"
HOST_META_FILE="/tmp/virttest-${RUN_ID}-host.json"
REMOTE_LOG_FILE="${REPORT_DIR}/${ENV_NAME}-remote.log"

SERVER_ID=""
SERVER_IP=""
SSH_USER="root"
SSH_PASSWORD=""

if [[ -z "${LIGHTNODE_PRIVATE_KEY:-}" && -z "${LIGHTNODE_SSH_PRIVATE_KEY:-}" && -z "${LIGHTNODE_PASSWORD:-}" ]]; then
  log_error "one of LIGHTNODE_PRIVATE_KEY, LIGHTNODE_SSH_PRIVATE_KEY, LIGHTNODE_PASSWORD is required"
  exit 2
fi

if [[ -n "${LIGHTNODE_PRIVATE_KEY:-}" || -n "${LIGHTNODE_SSH_PRIVATE_KEY:-}" ]]; then
  cat >"$SSH_KEY_FILE" <<<"${LIGHTNODE_PRIVATE_KEY:-${LIGHTNODE_SSH_PRIVATE_KEY:-}}"
  chmod 600 "$SSH_KEY_FILE"
fi

remote_exec() {
  local cmd="$1"
  if [[ -f "$SSH_KEY_FILE" ]]; then
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=15 -i "$SSH_KEY_FILE" "${SSH_USER}@${SERVER_IP}" "bash -se" <<EOF
set -euo pipefail
${cmd}
EOF
    then
      return 0
    fi
  fi

  if [[ -z "$SSH_PASSWORD" ]]; then
    return 1
  fi

  sshpass -p "${SSH_PASSWORD}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=15 "${SSH_USER}@${SERVER_IP}" "bash -se" <<EOF
set -euo pipefail
${cmd}
EOF
}

local_check() {
  local check_name="$1"
  local cmd="$2"
  local out_file="${REPORT_DIR}/${ENV_NAME}-${check_name// /_}.log"
  local started ended duration
  started=$(date +%s)
  if eval "$cmd" >"$out_file" 2>&1; then
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
  local started ended duration
  started=$(date +%s)
  if remote_exec "$cmd" >"$out_file" 2>&1; then
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

remote_wait_check() {
  local check_name="$1"
  local cmd="$2"
  local timeout_seconds="${3:-300}"
  local delay_seconds="${4:-5}"
  local max_delay_seconds="${5:-30}"
  local out_file="${REPORT_DIR}/${ENV_NAME}-${check_name// /_}.log"
  local started ended duration elapsed=0

  started=$(date +%s)
  while [[ "$elapsed" -lt "$timeout_seconds" ]]; do
    if remote_exec "$cmd" >"$out_file" 2>&1; then
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
  local -n step_ready="$1"
  local check_name="$2"
  local cmd="$3"
  local skip_reason="${4:-prerequisite failed}"

  if [[ "$step_ready" -ne 0 ]]; then
    if remote_check "$check_name" "$cmd"; then
      return 0
    fi
    step_ready=0
    return 1
  fi

  record_skip "$check_name" "$skip_reason"
  return 0
}

maybe_remote_wait_check() {
  local -n step_ready="$1"
  local check_name="$2"
  local cmd="$3"
  local timeout_seconds="${4:-300}"
  local delay_seconds="${5:-5}"
  local max_delay_seconds="${6:-30}"
  local skip_reason="${7:-prerequisite failed}"

  if [[ "$step_ready" -ne 0 ]]; then
    if remote_wait_check "$check_name" "$cmd" "$timeout_seconds" "$delay_seconds" "$max_delay_seconds"; then
      return 0
    fi
    step_ready=0
    return 1
  fi

  record_skip "$check_name" "$skip_reason"
  return 0
}

provision_host() {
  local out_file="${REPORT_DIR}/${ENV_NAME}-provision.log"
  local started ended duration
  started=$(date +%s)
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
  if "${PROVISION_DIR}/lightnode.sh" create >"${HOST_META_FILE}" 2>"$out_file"; then
    ended=$(date +%s)
    duration=$((ended - started))
    report_append_row "$REPORT_FILE" "provision_host" "PASS" "$duration" "ok"
    results_add "$RESULTS_FILE" "$ENV_NAME" "provision_host" "PASS" "$duration" "ok"
  else
    ended=$(date +%s)
    duration=$((ended - started))
    report_append_row "$REPORT_FILE" "provision_host" "FAIL" "$duration" "failed, see $(basename "$out_file")"
    results_add "$RESULTS_FILE" "$ENV_NAME" "provision_host" "FAIL" "$duration" "failed, see $(basename "$out_file")"
    return 1
  fi

  SERVER_ID="$(jq -r '.server_id' "$HOST_META_FILE")"
  SERVER_IP="$(jq -r '.ipv4' "$HOST_META_FILE")"
  SSH_PASSWORD="$(jq -r '.password // empty' "$HOST_META_FILE")"
  SSH_USER="$(jq -r '.ssh_user // "root"' "$HOST_META_FILE")"

  log_info "host ready id=${SERVER_ID} ip=${SERVER_IP}"
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
    if [[ -n "$SSH_PASSWORD" ]]; then
      if sshpass -p "${SSH_PASSWORD}" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
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

cleanup() {
  set +e
  if [[ -n "$SERVER_ID" ]]; then
    log_info "destroy host id=${SERVER_ID}"
    "${PROVISION_DIR}/lightnode.sh" destroy --server-id "$SERVER_ID" >/dev/null 2>&1 || true
  fi
  rm -f "$SSH_KEY_FILE" "$HOST_META_FILE"
}

trap cleanup EXIT

prepare_remote_repo() {
  remote_exec "
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y curl wget git jq ca-certificates
cd /root
rm -rf ${ENV_NAME}
git clone https://github.com/oneclickvirt/${ENV_NAME}.git /root/${ENV_NAME}
cd /root/${ENV_NAME}
chmod -R +x . || true
" >>"$REMOTE_LOG_FILE" 2>&1
}

run_case_docker() {
  local install_ready=1
  local resource_ready=1

  maybe_remote_check install_ready "docker_install" "
cd /root/docker
CN=false WITHOUTCDN=TRUE bash scripts/dockerinstall.sh
"
  maybe_remote_check resource_ready "docker_create_container" "
cd /root/docker
bash scripts/onedocker.sh vt-dk 1 512 VtPass123 25000 34975 35000 n debian 0
"
  maybe_remote_wait_check resource_ready "docker_wait_running" "docker inspect -f '{{.State.Running}}' vt-dk | grep -Fx true"
  maybe_remote_check resource_ready "docker_delete_container" "docker rm -f vt-dk"
  maybe_remote_wait_check resource_ready "docker_verify_deleted" "! docker ps -a --format '{{.Names}}' | grep -Fx vt-dk" 180 5 20
  maybe_remote_check install_ready "docker_uninstall" "
cd /root/docker
printf 'yes\n' | bash dockeruninstall.sh
"
}

run_case_containerd() {
  local install_ready=1
  local resource_ready=1

  maybe_remote_check install_ready "containerd_install" "
cd /root/containerd
WITHOUTCDN=TRUE bash containerdinstall.sh
"
  maybe_remote_check resource_ready "containerd_create_container" "
cd /root/containerd
bash scripts/onecontainerd.sh vt-ctd 1 512 VtPass123 25000 34975 35000 n debian 0
"
  maybe_remote_wait_check resource_ready "containerd_wait_running" "nerdctl inspect -f '{{.State.Status}}' vt-ctd | grep -Fx running"
  maybe_remote_check resource_ready "containerd_delete_container" "nerdctl rm -f vt-ctd"
  maybe_remote_wait_check resource_ready "containerd_verify_deleted" "! nerdctl ps -a | awk 'NR>1{print \$NF}' | grep -Fx vt-ctd" 180 5 20
  maybe_remote_check install_ready "containerd_uninstall" "
cd /root/containerd
CONFIRM_UNINSTALL=yes bash containerduninstall.sh
"
}

run_case_podman() {
  local install_ready=1
  local resource_ready=1

  maybe_remote_check install_ready "podman_install" "
cd /root/podman
WITHOUTCDN=TRUE bash podmaninstall.sh
"
  maybe_remote_check resource_ready "podman_create_container" "
cd /root/podman
bash scripts/onepodman.sh vt-pod 1 512 VtPass123 25000 34975 35000 n debian 0
"
  maybe_remote_wait_check resource_ready "podman_wait_running" "podman inspect -f '{{.State.Running}}' vt-pod | grep -Fx true"
  maybe_remote_check resource_ready "podman_delete_container" "podman rm -f vt-pod"
  maybe_remote_wait_check resource_ready "podman_verify_deleted" "! podman ps -a --format '{{.Names}}' | grep -Fx vt-pod" 180 5 20
  maybe_remote_check install_ready "podman_uninstall" "
cd /root/podman
FORCE_UNINSTALL=true bash podmanuninstall.sh
"
}

run_case_qemu() {
  local install_ready=1
  local resource_ready=1

  maybe_remote_check install_ready "qemu_install" "
cd /root/qemu
bash qemuinstall.sh
"
  maybe_remote_check resource_ready "qemu_create_vm" "
cd /root/qemu
bash scripts/oneqemu.sh vtqemu 1 1024 10 VtPass123 25000 34975 35000 debian12
"
  maybe_remote_wait_check resource_ready "qemu_wait_running" "virsh domstate vtqemu | grep -Fx running"
  maybe_remote_check resource_ready "qemu_delete_vm" "
cd /root/qemu
QEMU_FORCE_DELETE=yes bash scripts/delete_qemu.sh vtqemu -y
"
  maybe_remote_wait_check resource_ready "qemu_verify_deleted" "! virsh list --all --name | grep -Fx vtqemu" 180 5 20
  maybe_remote_check install_ready "qemu_uninstall" "
cd /root/qemu
QEMU_FORCE_UNINSTALL=yes bash qemuuninstall.sh
"
}

run_case_kubevirt() {
  local install_ready=1
  local resource_ready=1

  maybe_remote_check install_ready "kubevirt_install" "
cd /root/kubevirt
bash kubevirtinstall.sh
"
  maybe_remote_check resource_ready "kubevirt_create_vm" "
cd /root/kubevirt
bash scripts/onevm.sh vtkv 1 1 10 VtPass123 25000 34975 35000 ubuntu
"
  maybe_remote_wait_check resource_ready "kubevirt_wait_running" "kubectl get vmi -n kubevirt-vms vtkv -o jsonpath='{.status.phase}' | grep -Fx Running" 600 10 30
  maybe_remote_check resource_ready "kubevirt_delete_vm" "
cd /root/kubevirt
AUTO_YES=y bash scripts/deletevm.sh vtkv y
"
  maybe_remote_wait_check resource_ready "kubevirt_verify_deleted" "! kubectl get vm -n kubevirt-vms -o name | grep -Fx vm.kubevirt.io/vtkv" 180 5 20
  maybe_remote_check install_ready "kubevirt_uninstall" "
cd /root/kubevirt
AUTO_YES=y bash kubevirtuninstall.sh
"
}

run_case_lxd() {
  local install_ready=1
  local container_ready=1
  local vm_ready=1

  maybe_remote_check install_ready "lxd_install" "
cd /root/lxd
CN=false WITHOUTCDN=TRUE bash scripts/lxdinstall.sh
"
  maybe_remote_check container_ready "lxd_create_container" "
cd /root/lxd
bash scripts/buildct.sh vtlxdct 1 256 3 25000 0 0 1024 1024 n debian12
"
  maybe_remote_wait_check container_ready "lxd_wait_container_running" "lxc list --format csv -c n,s | awk -F, '\$1==\"vtlxdct\" && \$2==\"RUNNING\" {found=1} END {exit found ? 0 : 1}'"
  maybe_remote_check container_ready "lxd_delete_container" "lxc delete --force vtlxdct"
  maybe_remote_wait_check container_ready "lxd_verify_container_deleted" "! lxc list --format csv -c n | grep -Fx vtlxdct" 180 5 20

  maybe_remote_check vm_ready "lxd_create_vm" "
cd /root/lxd
bash scripts/buildvm.sh vtlxdvm 1 512 8 25001 0 0 1024 1024 n debian12
"
  maybe_remote_wait_check vm_ready "lxd_wait_vm_running" "lxc list --format csv -c n,s | awk -F, '\$1==\"vtlxdvm\" && \$2==\"RUNNING\" {found=1} END {exit found ? 0 : 1}'"
  maybe_remote_check vm_ready "lxd_delete_vm" "lxc delete --force vtlxdvm"
  maybe_remote_wait_check vm_ready "lxd_verify_vm_deleted" "! lxc list --format csv -c n | grep -Fx vtlxdvm" 180 5 20

  maybe_remote_check install_ready "lxd_uninstall" "
cd /root/lxd
FORCE=true bash scripts/lxduninstall.sh
"
}

run_case_incus() {
  local install_ready=1
  local container_ready=1
  local vm_ready=1

  maybe_remote_check install_ready "incus_install" "
cd /root/incus
CN=false WITHOUTCDN=TRUE bash scripts/incus_install.sh
"
  maybe_remote_check container_ready "incus_create_container" "
cd /root/incus
bash scripts/buildct.sh vtincusct 1 256 3 25000 0 0 1024 1024 n debian12
"
  maybe_remote_wait_check container_ready "incus_wait_container_running" "incus list --format csv -c n,s | awk -F, '\$1==\"vtincusct\" && \$2==\"RUNNING\" {found=1} END {exit found ? 0 : 1}'"
  maybe_remote_check container_ready "incus_delete_container" "incus delete --force vtincusct"
  maybe_remote_wait_check container_ready "incus_verify_container_deleted" "! incus list --format csv -c n | grep -Fx vtincusct" 180 5 20

  maybe_remote_check vm_ready "incus_create_vm" "
cd /root/incus
bash scripts/buildvm.sh vtincusvm 1 512 8 25001 0 0 1024 1024 n debian12
"
  maybe_remote_wait_check vm_ready "incus_wait_vm_running" "incus list --format csv -c n,s | awk -F, '\$1==\"vtincusvm\" && \$2==\"RUNNING\" {found=1} END {exit found ? 0 : 1}'"
  maybe_remote_check vm_ready "incus_delete_vm" "incus delete --force vtincusvm"
  maybe_remote_wait_check vm_ready "incus_verify_vm_deleted" "! incus list --format csv -c n | grep -Fx vtincusvm" 180 5 20

  maybe_remote_check install_ready "incus_uninstall" "
cd /root/incus
INCUS_FORCE_UNINSTALL=true bash scripts/uninstall_incus.sh
"
}

run_case_pve() {
  local install_ready=1
  local container_ready=1
  local vm_ready=1

  maybe_remote_check install_ready "pve_install" "
cd /root/pve
FORCE_INSTALL=true CN=false WITHOUTCDN=TRUE PVE_HOSTNAME=pvetest bash scripts/install_pve.sh
"

  maybe_remote_check container_ready "pve_create_container" "
cd /root/pve
bash scripts/buildct.sh 201 VtPass123 1 512 5 25000 0 0 0 0 debian12 local n
"
  maybe_remote_wait_check container_ready "pve_wait_container_running" "pct status 201 | grep -Fx 'status: running'"
  maybe_remote_check container_ready "pve_delete_container" "cd /root/pve && bash scripts/pve_delete.sh 201"
  maybe_remote_wait_check container_ready "pve_verify_container_deleted" "! pct list | awk 'NR>1{print \$1}' | grep -Fx 201" 180 5 20

  maybe_remote_check vm_ready "pve_create_vm" "
cd /root/pve
bash scripts/buildvm.sh 301 vtuser VtPass123 1 1024 10 25001 0 0 0 0 debian12 local n
"
  maybe_remote_wait_check vm_ready "pve_wait_vm_running" "qm status 301 | grep -Fx 'status: running'"
  maybe_remote_check vm_ready "pve_delete_vm" "cd /root/pve && bash scripts/pve_delete.sh 301"
  maybe_remote_wait_check vm_ready "pve_verify_vm_deleted" "! qm list | awk 'NR>1{print \$1}' | grep -Fx 301" 180 5 20

  maybe_remote_check install_ready "pve_uninstall" "
cd /root/pve
AUTO_CONFIRM=yes bash scripts/uninstall_pve.sh
"
}

log_info "starting env test: ${ENV_NAME}"

if ! provision_host; then
  exit 1
fi

if ! local_check "wait_ssh" "wait_ssh"; then
  exit 1
fi

if ! local_check "prepare_remote_repo" "prepare_remote_repo"; then
  exit 1
fi

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
  *)
    log_error "unsupported environment: $ENV_NAME"
    exit 2
    ;;
esac

if [[ "$TEST_FAILED" -ne 0 ]]; then
  log_error "test completed with failures for ${ENV_NAME}"
  exit 1
fi

log_ok "test completed for ${ENV_NAME}"
exit 0
