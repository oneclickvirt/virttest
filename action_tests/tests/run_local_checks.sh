#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_TESTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d)"

# shellcheck disable=SC2329
cleanup() {
  rm -rf "$TMP_DIR"
}
trap 'cleanup' EXIT

log() {
  printf '[local-check] %s\n' "$*"
}

fail() {
  printf '[local-check] FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  if ! grep -Fq "$needle" "$file"; then
    fail "expected ${file} to contain: ${needle}"
  fi
}

log "bash syntax"
while IFS= read -r f; do
  bash -n "$f"
done < <(find "$ACTION_TESTS_DIR" -type f -name "*.sh" | sort)

log "framework report and jsonl helpers"
# shellcheck source=action_tests/common/test_framework.sh
source "${ACTION_TESTS_DIR}/common/test_framework.sh"
framework_dir="${TMP_DIR}/framework"
ensure_dir "$framework_dir"
report_file="${framework_dir}/report.md"
results_file="${framework_dir}/results.jsonl"
PROMETHEUS_FILE="${framework_dir}/metrics.prom"
report_init "$report_file" "docker"
results_init "$results_file"
prometheus_init "$PROMETHEUS_FILE"
report_append_row "$report_file" "pipe_message" "PASS" "1" "contains | pipe"
results_add "$results_file" "docker" "pipe_message" "PASS" "1" "contains | pipe"
results_add "$results_file" "docker" "cleanup_message" "WARN" "0" "cleanup warning"
assert_file_contains "$report_file" "contains \\| pipe"
jq -e 'select(.environment == "docker" and .check == "pipe_message" and .duration_seconds == 1 and .status == "PASS")' "$results_file" >/dev/null
jq -e 'select(.check == "cleanup_message" and .status == "WARN")' "$results_file" >/dev/null
assert_file_contains "$PROMETHEUS_FILE" 'virttest_check_status{environment="docker",check="cleanup_message",status="WARN"} 1'

log "report index"
reports_dir="${TMP_DIR}/reports"
mkdir -p "${reports_dir}/docker/20260604-000000"
printf 'ok\n' >"${reports_dir}/docker/20260604-000000/docker-report.md"
printf '{"status":"WARN"}\n' >"${reports_dir}/docker/20260604-000000/docker-results.jsonl"
printf 'metric 1\n' >"${reports_dir}/docker/20260604-000000/docker-metrics.prom"
printf '{}\n' >"${reports_dir}/docker/20260604-000000/docker-resources.json"
bash "${ACTION_TESTS_DIR}/report/generate_index.sh" "$reports_dir" "${TMP_DIR}/index.html"
assert_file_contains "${TMP_DIR}/index.html" '"environment":"docker"'
assert_file_contains "${TMP_DIR}/index.html" "Filter environment, run, or file"
assert_file_contains "${TMP_DIR}/index.html" "docker-report.md"
assert_file_contains "${TMP_DIR}/index.html" "Warning latest"
assert_file_contains "${TMP_DIR}/index.html" "Prometheus"

log "report pruning and redaction"
prune_dir="${TMP_DIR}/prune/docker"
mkdir -p "${prune_dir}/20260601-000000" "${prune_dir}/20260602-000000" "${prune_dir}/20260603-000000"
bash "${ACTION_TESTS_DIR}/report/prune_reports.sh" "$prune_dir" 2 0
if [[ -d "${prune_dir}/20260601-000000" || ! -d "${prune_dir}/20260603-000000" ]]; then
  fail "report pruning did not keep the newest two runs"
fi
printf 'LIGHTNODE_TOKEN=abc password="secret" x-open-token: tok\n' | bash "${ACTION_TESTS_DIR}/common/redact_stream.sh" >"${TMP_DIR}/redacted.log"
assert_file_contains "${TMP_DIR}/redacted.log" "LIGHTNODE_TOKEN=[REDACTED]"
assert_file_contains "${TMP_DIR}/redacted.log" 'password=[REDACTED]'

log "run_env validation and skip recording"
if bash "${ACTION_TESTS_DIR}/run_env_test.sh" "../bad" >"${TMP_DIR}/invalid.out" 2>&1; then
  fail "invalid environment unexpectedly passed"
fi
assert_file_contains "${TMP_DIR}/invalid.out" "invalid environment name"

missing_report_dir="${TMP_DIR}/missing_config_reports"
if ! VIRTTEST_REPORT_DIR="$missing_report_dir" \
  LIGHTNODE_TOKEN="" \
  LIGHTNODE_PASSWORD="" \
  bash "${ACTION_TESTS_DIR}/run_env_test.sh" docker >"${TMP_DIR}/missing_config.out" 2>&1; then
  fail "missing provider configuration should skip instead of fail"
fi
assert_file_contains "${missing_report_dir}/docker-report.md" "| configuration | SKIP | 0 | missing required env:"
jq -e 'select(.check == "configuration" and .status == "SKIP")' "${missing_report_dir}/docker-results.jsonl" >/dev/null

# shellcheck source=action_tests/run_env_test.sh
source "${ACTION_TESTS_DIR}/run_env_test.sh"
ENV_NAME="docker"
REPORT_DIR="${TMP_DIR}/run_env_reports"
REPORT_FILE="${REPORT_DIR}/docker-report.md"
RESULTS_FILE="${REPORT_DIR}/docker-results.jsonl"
# shellcheck disable=SC2034
TEST_FAILED=0
ensure_dir "$REPORT_DIR"
report_init "$REPORT_FILE" "$ENV_NAME"
results_init "$RESULTS_FILE"
maybe_remote_check 0 "skipped_step" "false" "install failed"
assert_file_contains "$REPORT_FILE" "| skipped_step | SKIP | 0 | install failed |"
jq -e 'select(.check == "skipped_step" and .status == "SKIP" and .message == "install failed")' "$RESULTS_FILE" >/dev/null

log "remote ssh fallback isolation"
remote_bin="${TMP_DIR}/remote-bin"
mkdir -p "$remote_bin"
cat >"${remote_bin}/ssh" <<'MOCK_SSH'
#!/usr/bin/env bash
exit "${MOCK_SSH_RC:-42}"
MOCK_SSH
cat >"${remote_bin}/sshpass" <<'MOCK_SSHPASS'
#!/usr/bin/env bash
printf 'used\n' >"$MOCK_SSHPASS_MARKER"
exit 0
MOCK_SSHPASS
chmod +x "${remote_bin}/ssh" "${remote_bin}/sshpass"

SSH_KEY_FILE="${TMP_DIR}/dummy-ssh-key"
: >"$SSH_KEY_FILE"
SSH_PASSWORD="password"
SSH_USER="root"
SERVER_IP="203.0.113.20"
RUN_ID="local-run"
RESOURCE_SUFFIX="123456"
BASE_PORT=26000
PORT_HIGH=29975
PORT_FINAL=30000
PVE_CT_ID=2201
PVE_VM_ID=12201

old_path="$PATH"
PATH="${remote_bin}:$PATH"
export PATH
fallback_marker="${TMP_DIR}/sshpass-used"
export MOCK_SSHPASS_MARKER="$fallback_marker"

set +e
export MOCK_SSH_RC=42
remote_exec "exit 42" >"${TMP_DIR}/remote_exec_42.out" 2>&1
remote_exec_rc=$?
set -e
if [[ "$remote_exec_rc" -ne 42 ]]; then
  fail "expected remote command rc 42 without password fallback, got ${remote_exec_rc}"
fi
if [[ -f "$fallback_marker" ]]; then
  fail "password fallback ran for a non-SSH remote command failure"
fi

export MOCK_SSH_RC=255
remote_exec "true" >"${TMP_DIR}/remote_exec_255.out" 2>&1
if [[ ! -f "$fallback_marker" ]]; then
  fail "password fallback did not run for SSH connection failure"
fi
PATH="$old_path"
export PATH
unset MOCK_SSHPASS_MARKER MOCK_SSH_RC

log "mocked lightnode create"
mock_bin="${TMP_DIR}/bin"
mkdir -p "$mock_bin"
cat >"${mock_bin}/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
if [[ "${MOCK_LIGHTNODE_AUTH_FAIL:-}" == "1" ]]; then
  printf '{"message":"denied"}\n403\n'
  exit 0
fi

url=""
data=""
prev_arg=""
for arg in "$@"; do
  if [[ "$prev_arg" == "-d" ]]; then
    data="$arg"
    prev_arg=""
    continue
  fi
  if [[ "$arg" == "-d" ]]; then
    prev_arg="-d"
    continue
  fi
  url="$arg"
done
case "$url" in
  */region/list)
    printf '{"regions":[{"regionCode":"us","zones":[{"zoneCode":"us-a"}]},{"regionCode":"eu","zones":[{"zoneCode":"eu-a"}]}]}\n200\n'
    ;;
  */package/list*)
    case "$url" in
      *regionCode=eu*)
        printf '{"packages":[{"regionCode":"eu","zoneCode":"eu-a","packageCode":"pkg-eu"}]}\n200\n'
        ;;
      *)
        printf '{"packages":[{"regionCode":"us","zoneCode":"us-a","packageCode":"pkg-small"}]}\n200\n'
        ;;
    esac
    ;;
	  */image/list*)
	    printf '{"images":[{"osDistroVersion":"Debian 12","imageName":"Debian","imageResourceUUID":"img-debian"}]}\n200\n'
	    ;;
	  */instance/list*)
	    printf '{"instances":[{"ecsResourceUUID":"old-1","instanceName":"virttest-20200101000000"},{"ecsResourceUUID":"keep-1","instanceName":"other-20200101000000"}]}\n200\n'
	    ;;
  */instance/create)
    if [[ -n "${MOCK_CAPTURE_PAYLOAD:-}" ]]; then
      printf '%s\n' "$data" >"$MOCK_CAPTURE_PAYLOAD"
    fi
    printf '{"asyncTaskInfo":{"asyncTaskUUID":"task-1","ecsResourceUUID":"ecs-1"}}\n202\n'
    ;;
  */asynctask/getResult*)
    printf '{"asyncTaskInfo":{"processResult":"SUCCESS","taskStatus":"DONE"}}\n200\n'
    ;;
  */instance/detail*)
    printf '{"instance":{"publicIpAddress":"203.0.113.10","sysAccount":"root"}}\n200\n'
    ;;
  */instance/release)
    if [[ "${MOCK_RELEASE_FAIL:-}" == "1" ]]; then
      printf '{"message":"release failed"}\n500\n'
      exit 0
    fi
    printf '{"asyncTaskInfo":{"asyncTaskUUID":"task-release"}}\n202\n'
    ;;
  *)
    printf '{"message":"unexpected url","url":"%s"}\n404\n' "$url"
    ;;
esac
MOCK_CURL
chmod +x "${mock_bin}/curl"

lightnode_output="$(
  PATH="${mock_bin}:$PATH" \
  MOCK_CAPTURE_PAYLOAD="${TMP_DIR}/create_payload.json" \
  LIGHTNODE_TOKEN="token" \
  LIGHTNODE_PASSWORD="VtPass123!" \
  LIGHTNODE_REGION="us" \
  VIRTTEST_ENV_NAME="docker" \
  VIRTTEST_RESOURCE_SUFFIX="123456" \
  bash "${ACTION_TESTS_DIR}/provision/lightnode.sh" create
)"
jq -e '
  .server_id == "ecs-1" and
  .ipv4 == "203.0.113.10" and
  .ssh_user == "root" and
  .region == "us" and
  .zone == "us-a" and
  .password == "VtPass123!"
	' <<<"$lightnode_output" >/dev/null
jq -e '.packageConfig.instanceName | test("^virttest-[0-9]{14}-docker-123456$")' "${TMP_DIR}/create_payload.json" >/dev/null

lightnode_validate_output="$(
  PATH="${mock_bin}:$PATH" \
  LIGHTNODE_TOKEN="token" \
  LIGHTNODE_PASSWORD="VtPass123!" \
  LIGHTNODE_REGION="us" \
  bash "${ACTION_TESTS_DIR}/provision/lightnode.sh" validate
)"
jq -e '.status == "ok" and .platform == "lightnode" and .package_code == "pkg-small"' <<<"$lightnode_validate_output" >/dev/null

lightnode_zone_output="$(
  PATH="${mock_bin}:$PATH" \
  LIGHTNODE_TOKEN="token" \
  LIGHTNODE_PASSWORD="VtPass123!" \
  LIGHTNODE_ZONE="eu-a" \
  bash "${ACTION_TESTS_DIR}/provision/lightnode.sh" create
)"
jq -e '.region == "eu" and .zone == "eu-a"' <<<"$lightnode_zone_output" >/dev/null

set +e
lightnode_unavailable_output="$(
  PATH="${mock_bin}:$PATH" \
  LIGHTNODE_TOKEN="token" \
  LIGHTNODE_PASSWORD="VtPass123!" \
  LIGHTNODE_REGION="missing" \
  bash "${ACTION_TESTS_DIR}/provision/lightnode.sh" create 2>&1
)"
lightnode_unavailable_rc=$?
set -e
if [[ "$lightnode_unavailable_rc" -ne 3 ]]; then
  fail "expected unavailable LightNode inventory to exit 3, got ${lightnode_unavailable_rc}: ${lightnode_unavailable_output}"
fi

set +e
lightnode_auth_output="$(
  PATH="${mock_bin}:$PATH" \
  MOCK_LIGHTNODE_AUTH_FAIL=1 \
  LIGHTNODE_TOKEN="token" \
  LIGHTNODE_PASSWORD="VtPass123!" \
  bash "${ACTION_TESTS_DIR}/provision/lightnode.sh" create 2>&1
)"
lightnode_auth_rc=$?
set -e
if [[ "$lightnode_auth_rc" -ne 4 ]]; then
  fail "expected LightNode authentication failure to exit 4, got ${lightnode_auth_rc}: ${lightnode_auth_output}"
fi

set +e
lightnode_destroy_fail_output="$(
  PATH="${mock_bin}:$PATH" \
  MOCK_RELEASE_FAIL=1 \
  LIGHTNODE_TOKEN="token" \
  bash "${ACTION_TESTS_DIR}/provision/lightnode.sh" destroy --server-id ecs-1 2>&1
)"
lightnode_destroy_fail_rc=$?
set -e
if [[ "$lightnode_destroy_fail_rc" -ne 4 ]]; then
  fail "expected LightNode destroy failure to exit 4, got ${lightnode_destroy_fail_rc}: ${lightnode_destroy_fail_output}"
fi

dry_run_reports="${TMP_DIR}/dry_run_reports"
PATH="${mock_bin}:$PATH" \
  VIRTTEST_REPORT_DIR="$dry_run_reports" \
  LIGHTNODE_TOKEN="token" \
  LIGHTNODE_PASSWORD="VtPass123!" \
  LIGHTNODE_PRIVATE_KEY="dummy-key" \
  LIGHTNODE_REGION="us" \
  bash "${ACTION_TESTS_DIR}/run_env_test.sh" --dry-run docker >"${TMP_DIR}/dry_run.out" 2>&1
assert_file_contains "${dry_run_reports}/docker-report.md" "| dry_run | PASS | 0 |"
jq -e 'select(.check == "dry_run" and .status == "PASS")' "${dry_run_reports}/docker-results.jsonl" >/dev/null
assert_file_contains "${dry_run_reports}/docker-metrics.prom" "virttest_check_status"

log "dry-run without ssh tools"
dry_run_minimal_bin="${TMP_DIR}/dry-run-minimal-bin"
mkdir -p "$dry_run_minimal_bin"
ln -s "$mock_bin/curl" "${dry_run_minimal_bin}/curl"
for cmd in bash date dirname mktemp chmod mkdir jq sed tail printf sleep tr awk cksum grep basename rm wc cat; do
  cmd_path="$(command -v "$cmd")"
  if [[ -n "$cmd_path" ]]; then
    ln -s "$cmd_path" "${dry_run_minimal_bin}/${cmd}"
  fi
done
dry_run_no_ssh_reports="${TMP_DIR}/dry_run_no_ssh_reports"
PATH="$dry_run_minimal_bin" \
  VIRTTEST_REPORT_DIR="$dry_run_no_ssh_reports" \
  LIGHTNODE_TOKEN="token" \
  LIGHTNODE_PASSWORD="VtPass123!" \
  LIGHTNODE_REGION="us" \
  bash "${ACTION_TESTS_DIR}/run_env_test.sh" --dry-run docker >"${TMP_DIR}/dry_run_no_ssh.out" 2>&1
assert_file_contains "${dry_run_no_ssh_reports}/docker-report.md" "| dry_run | PASS | 0 |"
if grep -Fq "missing local command: ssh" "${TMP_DIR}/dry_run_no_ssh.out"; then
  fail "dry-run should not require ssh or sshpass"
fi

log "ok"
