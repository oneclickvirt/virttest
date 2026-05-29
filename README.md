# virttest

全量测试 oneclickvirt 相关项目安装、使用、创建/删除实例、卸载的自动化测试项目。

## 目标

- 覆盖项目：`pve`、`incus`、`docker`、`lxd`、`containerd`、`podman`、`qemu`、`kubevirt`
- 每次只测一个环境（GitHub Actions `max-parallel: 1`）
- 每个环境测试使用全新宿主机（默认 LightNode，新建后测试，结束即销毁）
- 在同一环境内，严格单实例串行：创建一个 -> 验证 -> 删除 -> 再测下一个
- 测试报告推送到独立分支（默认 `test-reports`）

## 目录

- `action_tests/run_env_test.sh`：单环境测试入口
- `action_tests/provision/lightnode.sh`：LightNode 主机创建/销毁
- `action_tests/common/test_framework.sh`：日志、结果、报告
- `action_tests/report/generate_index.sh`：报告索引页生成
- `.github/workflows/virttest-integration.yml`：CI 工作流

## 必需 Secrets

- `LIGHTNODE_TOKEN`：LightNode API Token
- `LIGHTNODE_PASSWORD`：LightNode 新建宿主机 root 密码，默认建议满足平台复杂度要求

## 可选 Secrets

- `LIGHTNODE_PRIVATE_KEY` 或 `LIGHTNODE_SSH_PRIVATE_KEY`：用于 SSH 登录 LightNode 宿主机的私钥
- `LIGHTNODE_SSH_KEY_UUID`：LightNode 控制台中已存在的 SSH Key UUID
- `LIGHTNODE_REGION`：指定区域
- `LIGHTNODE_ZONE`：指定可用区
- `LIGHTNODE_IMAGE_NAME`：宿主机默认镜像名，默认 `debian`

## 触发方式

手动触发 `Virttest Integration` workflow：

- `environment = all`：全量串行测试
- `environment = docker|lxd|...`：单环境测试
- `report_branch = test-reports`：报告分支

## 注意

- `pve`、`qemu`、`kubevirt` 对宿主机能力要求更高（KVM/嵌套虚拟化、磁盘、内存）
- 当前实现只适配 LightNode 作为宿主机供应商，其他云平台不再适配
- 若 LightNode 资源不足或 API/区域不可用，测试会记录为失败日志并保留报告
