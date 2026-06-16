# virttest

Language switch: English | [简体中文](README.zh-CN.md)

`virttest` is an automation harness for testing oneclickvirt projects end to end: install, create and verify a resource, delete it, uninstall the environment, and publish reports.

## Scope

- Supported environments: `pve`, `incus`, `docker`, `lxd`, `containerd`, `podman`, `qemu`, `kubevirt`
- CI first runs lightweight amd64 and arm64 checks on GitHub Actions local runners, then runs remote cloud-host integration tests
- Remote environments use a bounded supply pool (`remote_max_parallel`, default `3`) instead of global serialization
- Every environment gets a fresh LightNode host, which is destroyed after the test
- Within one environment, resource checks run in order: install -> create -> wait until usable -> delete -> verify deleted -> uninstall
- Reports are published to the `test-reports` branch by default, retaining the latest 7 runs per environment, with optional age-based pruning

## Architecture

- `.github/workflows/virttest-integration.yml`: manual workflow entry, amd64/arm64 local validation, remote environment matrix orchestration, artifact upload, report branch publishing, and final job failure propagation
- `action_tests/run_env_test.sh`: single-environment runner for input validation, host lifecycle, SSH readiness, remote repository setup, environment checks, and result files
- `action_tests/provision/lightnode.sh`: LightNode API adapter for region/zone selection, package and image selection, instance creation, async task polling, and release
- `action_tests/common/test_framework.sh`: Markdown reports, JSONL results, logging, and common check output
- `action_tests/common/runtime_helpers.sh`: argument parsing, deadline handling, timeout/retry wrappers, and per-run resource identifiers
- `action_tests/common/redact_stream.sh`: CI log redaction filter
- `action_tests/report/generate_index.sh`: report branch `index.html` generator
- `action_tests/report/prune_reports.sh`: report retention pruning by run count and optional age
- `action_tests/tests/run_local_checks.sh`: local verification that does not create cloud resources

## Real Remote Test Configuration

Real LightNode host creation needs these GitHub Secrets or local environment variables:

- `LIGHTNODE_TOKEN`: LightNode API token
- `LIGHTNODE_PASSWORD`: root password for the new host; also used as password SSH fallback

If either value is missing, the remote environment test records `configuration` as `SKIP` and exits successfully so an unconfigured repository does not fail CI. The amd64/arm64 local checks still run.

Optional configuration:

- `LIGHTNODE_PRIVATE_KEY` or `LIGHTNODE_SSH_PRIVATE_KEY`: SSH private key, preferred over password login
- `LIGHTNODE_SSH_KEY_UUID`: existing SSH key UUID in the LightNode console
- `LIGHTNODE_REGION`: target region; if only the region is set, the runner selects its first available zone
- `LIGHTNODE_ZONE`: target zone; if only the zone is set, the runner finds the matching region
- `LIGHTNODE_IMAGE_NAME`: host image name; defaults to `ubuntu` for `lxd/incus` and `debian` for the other environments
- `LIGHTNODE_INSTANCE_NAME_PREFIX`: host name prefix; created hosts use `<prefix>-<UTC timestamp>-<environment>-<resource suffix>` for parallel run isolation and stale cleanup

## Execution Order

1. CI first runs the `local-harness` job on amd64 and arm64 runners with `action_tests/tests/run_local_checks.sh` and ShellCheck.
2. Remote matrix jobs wait for local architecture validation. The single-environment runner validates the environment name before it is used in any local path or remote command.
3. The runner creates report files and checks `jq`; if the LightNode token or password is missing, it records `SKIP` and exits that environment.
4. With complete configuration, local dependencies are checked and a fresh LightNode host is created.
5. If LightNode has no matching region, zone, package, or image, `provision_host` is recorded as `SKIP`; authentication or create failures are still `FAIL`.
6. Provider inventory is preflighted before host creation. `--dry-run` stops here after writing reports and metrics.
7. SSH readiness is checked, base packages are installed, and the matching `oneclickvirt/<environment>` repository is shallow-cloned.
8. The environment-specific install, create, readiness, delete, delete verification, and uninstall checks run with per-step timeout and retry guards.
9. If a step fails, only dependent later steps are skipped. If installation succeeded, uninstall still runs and cleanup failures are recorded as `WARN`.
10. Artifacts and the report branch are published whenever possible. After publishing, CI fails the job if the real environment test exit code was non-zero.

## Local Verification

Local checks that do not create a cloud host:

```bash
bash action_tests/tests/run_local_checks.sh
```

Run one real environment test:

```bash
LIGHTNODE_TOKEN=... LIGHTNODE_PASSWORD=... bash action_tests/run_env_test.sh docker
```

## GitHub Actions

Trigger the `Virttest Integration` workflow manually:

- `environment = all`: run every environment sequentially
- `environment = docker|lxd|...`: run one environment
- `report_branch = test-reports`: report publishing branch
- `timeout_minutes = 210`: per-environment timeout
- `report_keep_runs = 7`: recent run count retained per environment on the report branch
- `report_keep_days = 0`: optional age-based report retention
- `remote_max_parallel = 3`: concurrent remote environment supply pool size
- `dry_run = false`: validate scripts, config, and provider inventory without creating a host
- `cleanup_stale_instances = false`: optional cleanup for stale LightNode instances matching the configured virttest prefix and age threshold
- `pr_number`: optional PR number for a report comment

Remote matrix artifacts are published to the report branch by one centralized job after all environment jobs finish, so parallel test jobs do not race when writing the report branch.

## Outputs

Each environment writes files under `action_tests/reports`:

- `<env>-report.md`: human-readable report
- `<env>-results.jsonl`: machine-readable per-check results
- `<env>-metrics.prom`: Prometheus-format metrics
- `<env>-resources.json`: host runtime, API-call, estimated-cost, and cleanup status summary
- `<env>-*.log`: per-check logs
- `<env>-full.log`: full CI execution output

Result states:

- `PASS`: the check passed
- `FAIL`: the check failed
- `WARN`: cleanup or non-critical maintenance failed without failing the core test
- `SKIP`: configuration is missing, provider resources are unavailable, or a prerequisite failed

The report branch `index.html` supports searching by environment, run, and file, plus filters for latest status, local architecture versus remote integration groups, and file type.

## Notes

- `pve`, `qemu`, and `kubevirt` require stronger host capabilities, usually KVM/nested virtualization plus more disk and memory.
- LightNode is the only implemented provisioner.
- This repository has no frontend service, backend API service, or local database. The main risks are Bash execution order, cloud host lifecycle, SSH credential fallback, remote command isolation, bounded provider concurrency, and CI failure propagation.
