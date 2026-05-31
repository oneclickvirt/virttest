# action_tests

本目录是 `virttest` 的自动化测试框架，用于验证 oneclickvirt 相关项目的安装、创建、删除与卸载流程。

它的设计目标是把“资源创建成功”“资源可用”“资源能删除”“环境可卸载”拆开验证，而不是只看脚本是否返回 0。

## 运行模型

每次测试都遵循同一条链路：

1. 通过 LightNode 创建全新宿主机
2. 等待宿主机 SSH 可用
3. 在宿主机上拉取对应项目仓库
4. 按环境执行安装、创建、验证、删除、卸载
5. 收集报告、日志与 JSONL 结果
6. 销毁宿主机并清理本地临时文件

当前实现约束如下：

- 每个环境使用全新宿主机，不复用上一次运行的系统状态
- 同一环境中按单资源串行执行，创建后立即验证并删除，再进入下一步
- 不同环境之间不会共享主机
- 如果某一步失败，后续依赖步骤会跳过，但前面的结果仍会完整落盘
- 最终退出码会反映是否存在失败，便于 CI 正确判定

## 快速开始

本地直接运行单环境：

```bash
bash action_tests/run_env_test.sh docker
```

可用环境名：

- `docker`
- `containerd`
- `podman`
- `qemu`
- `kubevirt`
- `lxd`
- `incus`
- `pve`

如果想看工作流方式，可以触发 `.github/workflows/virttest-integration.yml` 中的 `Virttest Integration`。

## 依赖

本地执行测试时，需要这些命令可用：

- `bash`
- `curl`
- `jq`
- `ssh`
- `sshpass`（当使用密码登录 LightNode 宿主机时）

GitHub Actions 工作流会自动安装这些基础依赖，但本地环境需要你自己准备。

## 必需配置

至少需要以下两项：

- `LIGHTNODE_TOKEN`
- `LIGHTNODE_PASSWORD`

`LIGHTNODE_TOKEN` 用于调用 LightNode API 创建和销毁宿主机；`LIGHTNODE_PASSWORD` 用于新宿主机的 root 密码，并作为密码 SSH 登录的回退方式。

## 可选配置

- `LIGHTNODE_PRIVATE_KEY` 或 `LIGHTNODE_SSH_PRIVATE_KEY`：SSH 私钥，优先于密码方式
- `LIGHTNODE_SSH_KEY_UUID`：LightNode 控制台中已存在的 SSH Key UUID
- `LIGHTNODE_REGION`：指定区域
- `LIGHTNODE_ZONE`：指定可用区
- `LIGHTNODE_IMAGE_NAME`：宿主机镜像名，未设置时默认按环境选择 `debian` 或 `ubuntu`

## 输出内容

每次运行都会生成以下文件：

- `action_tests/reports/<env>-report.md`：人类可读报告
- `action_tests/reports/<env>-results.jsonl`：逐项机器可读结果
- `action_tests/reports/<env>-*.log`：每个检查步骤的独立日志
- `action_tests/reports/<env>-full.log`：CI 中的完整执行输出

结果语义如下：

- `PASS`：该检查通过
- `FAIL`：该检查失败
- `SKIP`：由于前置步骤失败而跳过

说明：单项失败不会阻断后续结果写入，但最终脚本会返回非 0，这样既能保留完整报告，也能让 CI 失败状态准确上报。

## CI 工作流

`.github/workflows/virttest-integration.yml` 做了以下事情：

- `environment` 支持选择单个环境或 `all`
- `max-parallel: 1` 保证环境之间严格串行
- 每个环境单独产出 artifact
- 报告会推送到默认分支 `test-reports`，也可以通过输入参数覆盖
- 工作流会保留结果摘要，方便直接在 GitHub 页面查看总览

## Provision

当前只实现了 LightNode 作为宿主机供应商：

- `action_tests/provision/lightnode.sh create`
- `action_tests/provision/lightnode.sh destroy --server-id ...`

创建逻辑会自动处理以下事情：

- 查询可用区域和可用区
- 选择合适的套餐和镜像
- 等待异步创建任务完成
- 等待实例详情和公网 IP 可用

如果创建过程失败，脚本会尽力清理已经创建出来的实例，避免泄漏资源。

## 环境差异

不同环境的脚本并不完全一样，主要差别在于就绪判定和删除命令：

- `docker` / `podman` / `containerd`：验证容器处于运行状态，再删除并确认不存在
- `qemu` / `pve`：验证虚拟机状态后再删除
- `kubevirt`：会同时关注 VM 和 VMI 状态
- `lxd` / `incus`：容器和虚拟机都各自检查运行状态与删除结果

## 故障排查

如果测试失败，优先查看这几个位置：

- `action_tests/reports/<env>-report.md`：看是哪一步失败或被跳过
- `action_tests/reports/<env>-results.jsonl`：适合脚本化分析
- `action_tests/reports/<env>-full.log`：完整执行上下文
- `action_tests/reports/<env>-provision.log`：主机创建阶段错误
- `action_tests/reports/<env>-remote.log`：宿主机上拉仓库和基础准备阶段错误

常见原因：

- LightNode 资源不足、区域不可用或 API 异常
- 宿主机能力不满足 `pve`、`qemu`、`kubevirt` 对虚拟化的要求
- SSH 凭据不正确，或者宿主机还没完全就绪
- 远端仓库脚本本身失败，导致后续步骤被跳过

## 备注

- `pve`、`qemu`、`kubevirt` 对宿主机能力要求更高，通常需要 KVM 或嵌套虚拟化支持
- 当前实现只适配 LightNode，不包含其他云平台
- 若你新增环境，建议同时补充本文件中的运行模型、输出和故障排查说明
