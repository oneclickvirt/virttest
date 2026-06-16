# virttest

语言切换：[English](README.en.md) | 简体中文

`virttest` 用于全量测试 oneclickvirt 相关项目的安装、创建/验证实例、删除实例、卸载和报告发布流程。

## 覆盖范围

- 支持环境：`pve`、`incus`、`docker`、`lxd`、`containerd`、`podman`、`qemu`、`kubevirt`
- CI 先在 GitHub Actions 本地 runner 上分别执行 amd64 与 arm64 轻量验证，再进入远程云主机实例测试
- 远程环境使用有界供应池并发执行（`remote_max_parallel`，默认 `3`），不再全局串行
- 每个环境使用全新 LightNode 宿主机，测试结束后销毁
- 同一环境内按资源串行执行：安装 -> 创建 -> 等待可用 -> 删除 -> 确认删除 -> 卸载
- 测试报告默认发布到 `test-reports` 分支，每个环境默认保留最近 7 次运行，并支持按天数保留

## 架构

- `.github/workflows/virttest-integration.yml`：手动触发入口、amd64/arm64 本地验证、远程环境矩阵编排、artifact 上传、报告分支发布和最终失败状态回传
- `action_tests/run_env_test.sh`：单环境执行入口，负责输入校验、主机生命周期、SSH 准备、远端仓库准备、环境测试和结果落盘
- `action_tests/provision/lightnode.sh`：LightNode API 适配层，负责区域/可用区选择、套餐和镜像选择、实例创建、异步任务等待和销毁
- `action_tests/common/test_framework.sh`：Markdown 报告、JSONL 结果、日志和通用检查输出
- `action_tests/common/runtime_helpers.sh`：参数解析、deadline、超时/重试包装和每次运行的资源标识生成
- `action_tests/common/redact_stream.sh`：CI 日志脱敏过滤器
- `action_tests/report/generate_index.sh`：报告分支的 `index.html` 生成器
- `action_tests/report/prune_reports.sh`：按运行次数和可选天数清理旧报告
- `action_tests/tests/run_local_checks.sh`：不依赖云资源的本地验证脚本

## 真实远程测试配置

真实创建 LightNode 宿主机时需要 GitHub Secrets 或本地环境变量提供：

- `LIGHTNODE_TOKEN`：LightNode API Token
- `LIGHTNODE_PASSWORD`：创建宿主机时使用的 root 密码，也作为密码 SSH 登录的回退凭据

如果缺少以上配置，远程环境测试会记录 `configuration` 为 `SKIP` 并返回成功退出码，避免未配置仓库把 CI 标为失败。本地 amd64/arm64 轻量验证仍会照常运行。

可选配置：

- `LIGHTNODE_PRIVATE_KEY` 或 `LIGHTNODE_SSH_PRIVATE_KEY`：SSH 私钥，优先于密码登录
- `LIGHTNODE_SSH_KEY_UUID`：LightNode 控制台中已有 SSH Key UUID
- `LIGHTNODE_REGION`：指定区域；如果只设置区域，脚本会选择该区域下第一个可用区
- `LIGHTNODE_ZONE`：指定可用区；如果只设置可用区，脚本会反查匹配区域
- `LIGHTNODE_IMAGE_NAME`：宿主机镜像名；未设置时 `lxd/incus` 使用 `ubuntu`，其他环境使用 `debian`
- `LIGHTNODE_INSTANCE_NAME_PREFIX`：宿主机名称前缀；创建名称格式为 `<prefix>-<UTC 时间戳>-<environment>-<resource suffix>`，用于并发隔离和孤实例清理

## 执行时序

1. CI 先通过 `local-harness` 作业在 amd64 和 arm64 runner 上运行 `action_tests/tests/run_local_checks.sh` 与 ShellCheck。
2. 远程矩阵作业等待本地架构验证完成后开始；单环境测试入口先校验环境名，非法环境不会创建云主机，也不会参与本地路径或远端命令。
3. 生成报告文件并检查 `jq`；缺少 LightNode Token 或密码时记录 `SKIP` 后结束该环境。
4. 配置齐全时检查本地依赖，通过 LightNode 创建全新宿主机，等待实例详情和公网 IP 可用。
5. 如果 LightNode 没有匹配区域、可用区、套餐或镜像，记录 `provision_host` 为 `SKIP` 后结束该环境；鉴权或实例创建失败仍记为 `FAIL`。
6. 供应前先做平台库存预检；`--dry-run` 会在此阶段结束并写入报告与指标，不创建宿主机。
7. 等待 SSH 可用，安装基础依赖，浅克隆对应的 `oneclickvirt/<environment>` 仓库。
8. 按环境执行安装、资源创建、运行态验证、删除、删除确认和卸载，并对长步骤加超时和重试。
9. 某个步骤失败后，只跳过依赖它的后续步骤；安装成功时仍会尝试卸载清理，清理失败记录为 `WARN`。
10. artifact 和报告分支发布始终尽量执行；发布完成后，CI 根据真实测试退出码决定 job 是否失败。

## 本地验证

不创建云主机的本地验证：

```bash
bash action_tests/tests/run_local_checks.sh
```

运行单个真实环境测试：

```bash
LIGHTNODE_TOKEN=... LIGHTNODE_PASSWORD=... bash action_tests/run_env_test.sh docker
```

## GitHub Actions

手动触发 `Virttest Integration` workflow：

- `environment = all`：按矩阵顺序串行测试全部环境
- `environment = docker|lxd|...`：只测试指定环境
- `report_branch = test-reports`：报告发布分支
- `timeout_minutes = 210`：单环境超时时间
- `report_keep_runs = 7`：每个环境在报告分支保留的最近运行次数
- `report_keep_days = 0`：可选的按天数报告保留策略
- `remote_max_parallel = 3`：远程环境供应池并发数
- `dry_run = false`：只验证脚本、配置和供应商库存，不创建宿主机
- `cleanup_stale_instances = false`：可选清理超过年龄阈值且匹配 virttest 前缀的 LightNode 孤实例
- `pr_number`：可选 PR 编号，用于自动评论报告摘要

远程矩阵 artifact 会在所有环境 job 结束后由一个集中式发布 job 写入报告分支，避免并行测试 job 同时写报告分支造成竞态。

## 输出

每个环境会在 `action_tests/reports` 下生成：

- `<env>-report.md`：人类可读报告
- `<env>-results.jsonl`：逐项机器可读结果
- `<env>-metrics.prom`：Prometheus 格式指标
- `<env>-resources.json`：宿主机运行时长、API 调用、估算成本和清理状态摘要
- `<env>-*.log`：各检查步骤日志
- `<env>-full.log`：CI 中的完整执行输出

结果状态：

- `PASS`：检查通过
- `FAIL`：检查失败
- `WARN`：清理或非关键维护失败，不影响核心测试结果
- `SKIP`：配置缺失、平台资源不可用或前置条件失败，当前检查被跳过

报告分支的 `index.html` 支持按环境/运行时间/文件名搜索，并按最新状态、本地架构/远程集成分组和文件类型筛选。

## 注意事项

- `pve`、`qemu`、`kubevirt` 对宿主机能力要求更高，通常需要 KVM/嵌套虚拟化、更多磁盘和内存。
- 当前供应商只实现 LightNode；其他云平台没有适配层。
- 本项目没有前端服务、后端 API 服务或本地数据库；主要风险集中在 Bash 时序、云资源生命周期、SSH 凭据回退、远端命令隔离、有界供应商并发和 CI 失败状态传播。
