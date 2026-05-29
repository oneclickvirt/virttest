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

ensure_dir "$REPORT_DIR"
report_init "$REPORT_FILE" "$ENV_NAME"
results_init "$RESULTS_FILE"

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
  return 1
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
  local retries=90
  local i
  for i in $(seq 1 "$retries"); do
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
    sleep 5
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
  remote_check "docker_install" "
cd /root/docker
CN=false WITHOUTCDN=TRUE bash scripts/dockerinstall.sh
"
  remote_check "docker_create_container" "
cd /root/docker
bash scripts/onedocker.sh vt-dk 1 512 VtPass123 25000 34975 35000 n debian 0
"
  remote_check "docker_verify_created" "docker ps -a --format '{{.Names}}' | grep -Fx vt-dk"
  remote_check "docker_delete_container" "docker rm -f vt-dk"
  remote_check "docker_verify_deleted" "! docker ps -a --format '{{.Names}}' | grep -Fx vt-dk"
  remote_check "docker_uninstall" "
cd /root/docker
printf 'yes\n' | bash dockeruninstall.sh
"
}

run_case_containerd() {
  remote_check "containerd_install" "
cd /root/containerd
WITHOUTCDN=TRUE bash containerdinstall.sh
"
  remote_check "containerd_create_container" "
cd /root/containerd
bash scripts/onecontainerd.sh vt-ctd 1 512 VtPass123 25000 34975 35000 n debian 0
"
  remote_check "containerd_verify_created" "nerdctl ps -a | awk 'NR>1{print \$NF}' | grep -Fx vt-ctd"
  remote_check "containerd_delete_container" "nerdctl rm -f vt-ctd"
  remote_check "containerd_verify_deleted" "! nerdctl ps -a | awk 'NR>1{print \$NF}' | grep -Fx vt-ctd"
  remote_check "containerd_uninstall" "
cd /root/containerd
CONFIRM_UNINSTALL=yes bash containerduninstall.sh
"
}

run_case_podman() {
  remote_check "podman_install" "
cd /root/podman
WITHOUTCDN=TRUE bash podmaninstall.sh
"
  remote_check "podman_create_container" "
cd /root/podman
bash scripts/onepodman.sh vt-pod 1 512 VtPass123 25000 34975 35000 n debian 0
"
  remote_check "podman_verify_created" "podman ps -a --format '{{.Names}}' | grep -Fx vt-pod"
  remote_check "podman_delete_container" "podman rm -f vt-pod"
  remote_check "podman_verify_deleted" "! podman ps -a --format '{{.Names}}' | grep -Fx vt-pod"
  remote_check "podman_uninstall" "
cd /root/podman
FORCE_UNINSTALL=true bash podmanuninstall.sh
"
}

run_case_qemu() {
  remote_check "qemu_install" "
cd /root/qemu
bash qemuinstall.sh
"
  remote_check "qemu_create_vm" "
cd /root/qemu
bash scripts/oneqemu.sh vtqemu 1 1024 10 VtPass123 25000 34975 35000 debian12
"
  remote_check "qemu_verify_created" "virsh list --all --name | grep -Fx vtqemu"
  remote_check "qemu_delete_vm" "
cd /root/qemu
QEMU_FORCE_DELETE=yes bash scripts/delete_qemu.sh vtqemu -y
"
  remote_check "qemu_verify_deleted" "! virsh list --all --name | grep -Fx vtqemu"
  remote_check "qemu_uninstall" "
cd /root/qemu
QEMU_FORCE_UNINSTALL=yes bash qemuuninstall.sh
"
}

run_case_kubevirt() {
  remote_check "kubevirt_install" "
cd /root/kubevirt
bash kubevirtinstall.sh
"
  remote_check "kubevirt_create_vm" "
cd /root/kubevirt
bash scripts/onevm.sh vtkv 1 1 10 VtPass123 25000 34975 35000 ubuntu
"
  remote_check "kubevirt_verify_created" "kubectl get vm -n kubevirt-vms -o name | grep -Fx vm.kubevirt.io/vtkv"
  remote_check "kubevirt_delete_vm" "
cd /root/kubevirt
AUTO_YES=y bash scripts/deletevm.sh vtkv y
"
  remote_check "kubevirt_verify_deleted" "! kubectl get vm -n kubevirt-vms -o name | grep -Fx vm.kubevirt.io/vtkv"
  remote_check "kubevirt_uninstall" "
cd /root/kubevirt
AUTO_YES=y bash kubevirtuninstall.sh
"
}

run_case_lxd() {
  remote_check "lxd_install" "
cd /root/lxd
CN=false WITHOUTCDN=TRUE bash scripts/lxdinstall.sh
"
  remote_check "lxd_create_container" "
cd /root/lxd
bash scripts/buildct.sh vtlxdct 1 256 3 25000 0 0 1024 1024 n debian12
"
  remote_check "lxd_verify_container_created" "lxc list --format csv -c n | grep -Fx vtlxdct"
  remote_check "lxd_delete_container" "lxc delete --force vtlxdct"
  remote_check "lxd_verify_container_deleted" "! lxc list --format csv -c n | grep -Fx vtlxdct"

  remote_check "lxd_create_vm" "
cd /root/lxd
bash scripts/buildvm.sh vtlxdvm 1 512 8 25001 0 0 1024 1024 n debian12
"
  remote_check "lxd_verify_vm_created" "lxc list --format csv -c n | grep -Fx vtlxdvm"
  remote_check "lxd_delete_vm" "lxc delete --force vtlxdvm"
  remote_check "lxd_verify_vm_deleted" "! lxc list --format csv -c n | grep -Fx vtlxdvm"

  remote_check "lxd_uninstall" "
cd /root/lxd
FORCE=true bash scripts/lxduninstall.sh
"
}

run_case_incus() {
  remote_check "incus_install" "
cd /root/incus
CN=false WITHOUTCDN=TRUE bash scripts/incus_install.sh
"
  remote_check "incus_create_container" "
cd /root/incus
bash scripts/buildct.sh vtincusct 1 256 3 25000 0 0 1024 1024 n debian12
"
  remote_check "incus_verify_container_created" "incus list --format csv -c n | grep -Fx vtincusct"
  remote_check "incus_delete_container" "incus delete --force vtincusct"
  remote_check "incus_verify_container_deleted" "! incus list --format csv -c n | grep -Fx vtincusct"

  remote_check "incus_create_vm" "
cd /root/incus
bash scripts/buildvm.sh vtincusvm 1 512 8 25001 0 0 1024 1024 n debian12
"
  remote_check "incus_verify_vm_created" "incus list --format csv -c n | grep -Fx vtincusvm"
  remote_check "incus_delete_vm" "incus delete --force vtincusvm"
  remote_check "incus_verify_vm_deleted" "! incus list --format csv -c n | grep -Fx vtincusvm"

  remote_check "incus_uninstall" "
cd /root/incus
INCUS_FORCE_UNINSTALL=true bash scripts/uninstall_incus.sh
"
}

run_case_pve() {
  remote_check "pve_install" "
cd /root/pve
FORCE_INSTALL=true CN=false WITHOUTCDN=TRUE PVE_HOSTNAME=pvetest bash scripts/install_pve.sh
"

  remote_check "pve_create_container" "
cd /root/pve
bash scripts/buildct.sh 201 VtPass123 1 512 5 25000 0 0 0 0 debian12 local n
"
  remote_check "pve_verify_container_created" "pct list | awk 'NR>1{print \$1}' | grep -Fx 201"
  remote_check "pve_delete_container" "cd /root/pve && bash scripts/pve_delete.sh 201"
  remote_check "pve_verify_container_deleted" "! pct list | awk 'NR>1{print \$1}' | grep -Fx 201"

  remote_check "pve_create_vm" "
cd /root/pve
bash scripts/buildvm.sh 301 vtuser VtPass123 1 1024 10 25001 0 0 0 0 debian12 local n
"
  remote_check "pve_verify_vm_created" "qm list | awk 'NR>1{print \$1}' | grep -Fx 301"
  remote_check "pve_delete_vm" "cd /root/pve && bash scripts/pve_delete.sh 301"
  remote_check "pve_verify_vm_deleted" "! qm list | awk 'NR>1{print \$1}' | grep -Fx 301"

  remote_check "pve_uninstall" "
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

log_ok "test completed for ${ENV_NAME}"
exit 0
