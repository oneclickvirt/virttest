# action_tests

本目录是 virttest 的自动化测试框架，参考 oneclickvirt/action_tests 思路实现，并按本仓库目标做了约束：

- 每个环境测试都在全新宿主机执行（云 API 新建主机）
- 一个环境一次只测一个资源，创建后立即删除，再进行下一项
- 环境切换不复用宿主机（销毁旧主机后重建，等价“重装系统”）

## 入口

```bash
bash action_tests/run_env_test.sh docker
```

输出目录：

- `action_tests/reports/<env>-report.md`
- `action_tests/reports/<env>-results.jsonl`
- `action_tests/reports/<env>-*.log`

## Provision

当前实现只提供 `LightNode`：

- `action_tests/provision/lightnode.sh create`
- `action_tests/provision/lightnode.sh destroy --server-id ...`

## CI Workflow

`.github/workflows/virttest-integration.yml` 提供：

- `environment`：单环境或 `all`
- `max-parallel: 1`：严格串行
- 报告推送分支：默认 `test-reports`

## 必需环境变量/Secrets

- `LIGHTNODE_TOKEN`
- `LIGHTNODE_PASSWORD`

## 可选环境变量/Secrets

- `LIGHTNODE_PRIVATE_KEY` 或 `LIGHTNODE_SSH_PRIVATE_KEY`
- `LIGHTNODE_SSH_KEY_UUID`
- `LIGHTNODE_REGION`
- `LIGHTNODE_ZONE`
- `LIGHTNODE_IMAGE_NAME`
