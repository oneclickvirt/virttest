# action_tests

语言切换：[English](README.en.md) | 简体中文

本目录是 `virttest` 的自动化测试框架，用于验证 oneclickvirt 相关项目的安装、资源创建、运行态验证、删除、删除确认与卸载流程。

## 运行模型

每次单环境测试遵循同一条链路：

1. 校验环境名，只允许 `pve|incus|docker|lxd|containerd|podman|qemu|kubevirt`
2. 初始化 Markdown 报告和 JSONL 结果，确认 `jq` 可用
3. 检查 LightNode Token 和密码；未配置时记录 `configuration` 为 `SKIP` 并结束该环境
4. 配置齐全时检查本地依赖，通过 LightNode 创建全新宿主机
5. 供应商库存预检；`--dry-run` 会在此阶段结束并写入报告、JSONL、Prometheus 和资源摘要
6. 等待宿主机详情、公网 IP 和 SSH 可用
7. 在宿主机上安装基础依赖并克隆对应 `oneclickvirt/<env>` 仓库
8. 执行环境安装、资源创建、运行态验证、删除、删除确认和卸载，并加超时与重试保护
9. 写入 Markdown 报告、JSONL 结果、Prometheus 指标、资源核算和每步日志
10. 销毁宿主机并删除本地临时密钥/元数据文件

失败处理规则：

- 缺少 `LIGHTNODE_TOKEN` 或 `LIGHTNODE_PASSWORD` 时，视为仓库未配置，记录 `SKIP` 并返回成功退出码
- LightNode 无匹配区域、可用区、套餐或镜像时，视为外部平台不可用，记录 `provision_host` 为 `SKIP` 并返回成功退出码
- LightNode 鉴权、实例创建或异步任务失败仍记录为 `FAIL`
- 安装失败时，依赖安装结果的创建、验证、删除和卸载步骤会按依赖关系记录为 `SKIP` 或停止执行
- 创建失败时，运行态验证、删除和删除确认会跳过
- 安装成功后，即使资源创建或验证失败，也会尽量继续执行卸载步骤；卸载/清理失败记录为 `WARN`，不作为核心测试失败
- `run_env_test.sh` 的最终退出码会反映是否存在失败；CI 会在 artifact 和报告发布后再回传失败状态

## 文件说明

- `run_env_test.sh`：单环境测试入口
- `provision/lightnode.sh`：LightNode 创建/销毁实现
- `common/test_framework.sh`：日志、Markdown 报告和 JSONL 结果工具
- `common/runtime_helpers.sh`：参数解析、deadline、超时/重试包装和资源标识生成
- `common/redact_stream.sh`：CI 日志脱敏过滤器
- `report/generate_index.sh`：报告分支索引页生成器
- `report/prune_reports.sh`：按次数/天数保留报告的清理工具
- `tests/run_local_checks.sh`：不创建云主机的本地验证脚本

## 本地验证

本地轻量验证不会调用真实 LightNode API：

```bash
bash action_tests/tests/run_local_checks.sh
```

覆盖内容：

- 所有 Bash 脚本语法
- 报告和 JSONL 写入
- 报告索引页生成、搜索和状态/分组筛选数据
- 非法环境名前置拦截
- 缺少 LightNode 配置时的 `SKIP` 退出语义
- `SKIP` 结果记录
- Prometheus 指标输出
- 报告清理和日志脱敏
- LightNode 预检/创建路径的 mock API 响应解析

## 真实环境运行

```bash
LIGHTNODE_TOKEN=... LIGHTNODE_PASSWORD=... bash action_tests/run_env_test.sh docker
```

只预检不创建宿主机：

```bash
LIGHTNODE_TOKEN=... LIGHTNODE_PASSWORD=... bash action_tests/run_env_test.sh --dry-run docker
```

可用环境：

- `docker`
- `containerd`
- `podman`
- `qemu`
- `kubevirt`
- `lxd`
- `incus`
- `pve`

## 依赖

本地运行真实测试需要：

- `bash`
- `curl`
- `jq`
- `ssh`：真实环境运行通过供应商预检后需要；`--dry-run` 不需要
- `sshpass`：仅真实环境运行且没有提供 SSH 私钥，或私钥失败后需要密码回退时必需

GitHub Actions 会自动安装基础依赖。

## 真实环境配置

- `LIGHTNODE_TOKEN`
- `LIGHTNODE_PASSWORD`

`LIGHTNODE_PASSWORD` 不再使用脚本内置默认值；缺少 Token 或密码时不会创建云主机，而是写入 `configuration` 的 `SKIP` 结果并返回成功退出码。

## 可选配置

- `LIGHTNODE_PRIVATE_KEY` 或 `LIGHTNODE_SSH_PRIVATE_KEY`
- `LIGHTNODE_SSH_KEY_UUID`
- `LIGHTNODE_REGION`
- `LIGHTNODE_ZONE`
- `LIGHTNODE_IMAGE_NAME`
- `LIGHTNODE_API_BASE`
- `LIGHTNODE_INSTANCE_NAME_PREFIX`：创建的宿主机名称使用 `<prefix>-<UTC 时间戳>-<environment>-<resource suffix>`，避免并发运行碰撞，并让孤实例清理能识别旧 virttest 主机
- `LIGHTNODE_HOURLY_COST_USD`：用于资源核算的可选小时成本估算
- `VIRTTEST_STEP_TIMEOUT_SECONDS`、`VIRTTEST_PROVISION_TIMEOUT_SECONDS`、`VIRTTEST_REMOTE_RETRIES`
- `VIRTTEST_CLEANUP_STALE=1`：按 virttest 前缀和年龄阈值清理 LightNode 孤实例

如果只设置 `LIGHTNODE_REGION`，脚本会使用该区域下第一个可用区；如果只设置 `LIGHTNODE_ZONE`，脚本会从区域列表中反查匹配区域。

## 输出

每次运行会生成：

- `action_tests/reports/<env>-report.md`
- `action_tests/reports/<env>-results.jsonl`
- `action_tests/reports/<env>-metrics.prom`
- `action_tests/reports/<env>-resources.json`
- `action_tests/reports/<env>-*.log`
- `action_tests/reports/<env>-full.log`：由 CI tee 生成

结果语义：

- `PASS`：该检查通过
- `FAIL`：该检查失败
- `WARN`：清理或维护失败，但不影响核心测试结果
- `SKIP`：未配置、平台不可用或前置条件失败，当前检查被跳过

## 环境差异

- `docker` / `podman` / `containerd`：验证容器进入运行状态，再删除并确认不存在
- `qemu`：验证 libvirt VM 为 `running`，再通过原项目删除脚本删除
- `kubevirt`：验证 VMI phase 为 `Running`，删除后确认 VM 不存在
- `lxd` / `incus`：容器和 VM 分别创建、验证、删除和确认删除
- `pve`：分别创建 CT 和 VM，使用 `pct/qm` 状态确认运行态并用 `pve_delete.sh` 删除

## 故障排查

优先查看：

- `action_tests/reports/<env>-report.md`
- `action_tests/reports/<env>-results.jsonl`
- `action_tests/reports/<env>-full.log`
- `action_tests/reports/<env>-provision.log`
- `action_tests/reports/<env>-remote.log`

常见原因：

- LightNode Token、密码、区域、可用区、套餐或镜像不可用
- SSH 私钥不匹配，且缺少 `sshpass` 进行密码回退
- `pve`、`qemu`、`kubevirt` 所需虚拟化能力不足
- 远端 `oneclickvirt/<env>` 项目脚本变更导致参数或状态判定不再匹配
