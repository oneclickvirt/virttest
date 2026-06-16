# action_tests

Language switch: English | [简体中文](README.zh-CN.md)

This directory contains the `virttest` automation framework for oneclickvirt environment installation, resource creation, readiness verification, deletion, delete verification, and uninstall flows.

## Runtime Model

Every single-environment test follows the same chain:

1. Validate the environment name. Only `pve|incus|docker|lxd|containerd|podman|qemu|kubevirt` is accepted.
2. Initialize Markdown and JSONL result files, then confirm `jq` is available.
3. Check the LightNode token and password. If either is missing, record `configuration` as `SKIP` and end that environment.
4. With complete configuration, check local dependencies and create a fresh LightNode host.
5. Preflight provider inventory. `--dry-run` exits here after writing report, JSONL, Prometheus, and resource summary files.
6. Wait for host details, public IPv4, and SSH readiness.
7. Install base packages on the host and clone the matching `oneclickvirt/<env>` repository.
8. Run install, create, readiness, delete, delete verification, and uninstall checks with bounded timeout and retry guards.
9. Write Markdown reports, JSONL results, Prometheus metrics, resource accounting, and per-step logs.
10. Destroy the host and remove local temporary key/metadata files.

Failure handling:

- Missing `LIGHTNODE_TOKEN` or `LIGHTNODE_PASSWORD` means the repository is not configured; the runner records `SKIP` and returns a successful exit code.
- Missing matching LightNode regions, zones, packages, or images means the external provider is unavailable; `provision_host` is recorded as `SKIP` and the runner returns successfully.
- LightNode authentication, instance create, or async task failures are still recorded as `FAIL`.
- If install fails, dependent create, verify, delete, and uninstall steps are skipped or stopped according to dependency order.
- If create fails, readiness, delete, and delete verification are skipped.
- If install succeeds, uninstall is attempted even when resource creation or verification fails. Uninstall/cleanup failure is recorded as `WARN`, not as a core test failure.
- `run_env_test.sh` returns a non-zero exit code when any check fails. CI publishes artifacts and reports first, then propagates that failure.

## Files

- `run_env_test.sh`: single-environment runner
- `provision/lightnode.sh`: LightNode create/release implementation
- `common/test_framework.sh`: logging, Markdown reports, and JSONL results
- `common/runtime_helpers.sh`: argument parsing, deadlines, timeout/retry wrappers, and resource identifiers
- `common/redact_stream.sh`: CI log redaction filter
- `report/generate_index.sh`: report branch index page generator
- `report/prune_reports.sh`: count/age report retention helper
- `tests/run_local_checks.sh`: local verification without cloud resources

## Local Verification

Lightweight local verification does not call the real LightNode API:

```bash
bash action_tests/tests/run_local_checks.sh
```

It covers:

- Bash syntax for every script
- Report and JSONL output helpers
- Report index generation plus search and status/group filter data
- Early rejection of invalid environment names
- Missing LightNode configuration `SKIP` exit semantics
- `SKIP` result recording
- Prometheus metric output
- Report pruning and log redaction
- Mocked LightNode validate/create response parsing

## Real Environment Run

```bash
LIGHTNODE_TOKEN=... LIGHTNODE_PASSWORD=... bash action_tests/run_env_test.sh docker
```

Dry-run preflight without creating a host:

```bash
LIGHTNODE_TOKEN=... LIGHTNODE_PASSWORD=... bash action_tests/run_env_test.sh --dry-run docker
```

Available environments:

- `docker`
- `containerd`
- `podman`
- `qemu`
- `kubevirt`
- `lxd`
- `incus`
- `pve`

## Dependencies

Real local runs need:

- `bash`
- `curl`
- `jq`
- `ssh`: required for real environment runs after provider preflight; not required for `--dry-run`
- `sshpass`: required for real environment runs only when no SSH private key is supplied, or when password fallback is needed after key login fails

GitHub Actions installs the base dependencies automatically.

## Real Environment Configuration

- `LIGHTNODE_TOKEN`
- `LIGHTNODE_PASSWORD`

`LIGHTNODE_PASSWORD` no longer has a hard-coded default inside the scripts. Missing token or password configuration does not create a cloud host; it writes a `configuration` `SKIP` result and exits successfully.

## Optional Configuration

- `LIGHTNODE_PRIVATE_KEY` or `LIGHTNODE_SSH_PRIVATE_KEY`
- `LIGHTNODE_SSH_KEY_UUID`
- `LIGHTNODE_REGION`
- `LIGHTNODE_ZONE`
- `LIGHTNODE_IMAGE_NAME`
- `LIGHTNODE_API_BASE`
- `LIGHTNODE_INSTANCE_NAME_PREFIX`: created host names use `<prefix>-<UTC timestamp>-<environment>-<resource suffix>` so parallel runs do not collide and stale cleanup can identify old virttest hosts
- `LIGHTNODE_HOURLY_COST_USD`: optional estimate used for resource accounting
- `VIRTTEST_STEP_TIMEOUT_SECONDS`, `VIRTTEST_PROVISION_TIMEOUT_SECONDS`, `VIRTTEST_REMOTE_RETRIES`
- `VIRTTEST_CLEANUP_STALE=1`: enable stale LightNode cleanup by virttest prefix and age threshold

If only `LIGHTNODE_REGION` is set, the script selects the first available zone in that region. If only `LIGHTNODE_ZONE` is set, the script finds the matching region from the region list.

## Outputs

Each run writes:

- `action_tests/reports/<env>-report.md`
- `action_tests/reports/<env>-results.jsonl`
- `action_tests/reports/<env>-metrics.prom`
- `action_tests/reports/<env>-resources.json`
- `action_tests/reports/<env>-*.log`
- `action_tests/reports/<env>-full.log`: created by CI with `tee`

Result states:

- `PASS`: the check passed
- `FAIL`: the check failed
- `WARN`: cleanup or maintenance failed without failing the core test
- `SKIP`: configuration is missing, the provider is unavailable, or a prerequisite failed

## Environment Differences

- `docker` / `podman` / `containerd`: verify the container is running, then delete it and confirm it no longer exists.
- `qemu`: verify the libvirt VM is `running`, then delete it through the upstream delete script.
- `kubevirt`: verify VMI phase is `Running`, then confirm the VM is gone after deletion.
- `lxd` / `incus`: create, verify, delete, and verify deletion for both a container and a VM.
- `pve`: create both CT and VM resources, verify runtime state with `pct/qm`, and delete through `pve_delete.sh`.

## Troubleshooting

Start with:

- `action_tests/reports/<env>-report.md`
- `action_tests/reports/<env>-results.jsonl`
- `action_tests/reports/<env>-full.log`
- `action_tests/reports/<env>-provision.log`
- `action_tests/reports/<env>-remote.log`

Common causes:

- LightNode token, password, region, zone, package, or image is unavailable.
- SSH private key does not match and `sshpass` is missing for password fallback.
- Host capabilities are insufficient for `pve`, `qemu`, or `kubevirt`.
- Upstream `oneclickvirt/<env>` scripts changed parameters or status semantics.
