# Codex CLI worker（可选）

`wsl/poller.sh` 可以在同一个 poller、同一个全局 `flock` 下调度 Claude CLI 或 Codex CLI。默认行为仍然是 Claude；不配置任何新变量时，现有部署不变。

## 任务如何选择 worker

在 `status/NNN.json` 里可选地增加 `worker`：

```json
{"task":"100","state":"queued","round":0,"worker":"codex","updated":"..."}
```

允许值：

- `claude`：调用 Claude CLI；也是默认值。
- `codex`：调用 Codex CLI。
- `manual`：保留人工处理，poller 只记录 skip，不认领任务。

没有 `worker` 字段时，使用 `PIPELINE_DEFAULT_WORKER`；该变量也未设置时回退到 `claude`。

`PIPELINE_LOCAL_WORKERS` 是这台机器的本地能力列表，而不是第二套派单规则。例如：

```bash
export PIPELINE_LOCAL_WORKERS=claude,codex
```

任务指定了 `codex`，但本机能力列表没有 `codex` 时，任务保持原状态，不会先变成 `doing`。

## Codex 一次性准备

安装并登录 Codex CLI，然后确认非交互登录检查成功：

```bash
codex login
codex login status
```

cron 的 PATH 通常比交互 shell 短。poller 会补上 `~/.local/bin` 和 `~/.npm-global/bin`，也可以显式指定可执行文件：

```bash
export PIPELINE_CODEX_BIN="$HOME/.npm-global/bin/codex"
```

## 配置项

| 变量 | 默认值 | 说明 |
|---|---|---|
| `PIPELINE_LOCAL_WORKERS` | `PIPELINE_DEFAULT_WORKER` | 本机可运行的 worker，逗号分隔 |
| `PIPELINE_DEFAULT_WORKER` | `claude` | status 未声明 worker 时的默认值 |
| `PIPELINE_CLAUDE_BIN` | `claude` | Claude CLI 路径或命令名 |
| `PIPELINE_MODEL` | 空 | Claude 模型覆盖；空值使用本机默认 |
| `PIPELINE_CODEX_BIN` | `codex` | Codex CLI 路径或命令名 |
| `PIPELINE_CODEX_MODEL` | 空 | Codex 模型覆盖；空值使用 CLI / 账户默认 |
| `PIPELINE_CODEX_REASONING_EFFORT` | `high` | 通过 `model_reasoning_effort` 传给 Codex |
| `PIPELINE_CODEX_SANDBOX` | `workspace-write` | 仅允许 `read-only` 或 `workspace-write` |
| `PIPELINE_RUN_ROOT` | `~/.local/state/pipeline-bus/runs` | 私有运行日志与临时 clone 的根目录 |

推荐部署：

```bash
export PIPELINE_LOCAL_WORKERS=claude,codex
export PIPELINE_CODEX_REASONING_EFFORT=high
export PIPELINE_CODEX_SANDBOX=workspace-write
```

模型名不写死在仓库里，避免把某台机器或某个账户的内部别名变成公共默认值。

## 非交互调用形态

poller 生成的 Codex 命令等价于：

```bash
codex \
  -a never \
  --sandbox workspace-write \
  -C <disposable-worker-clone> \
  [-m "$PIPELINE_CODEX_MODEL"] \
  -c model_reasoning_effort=high \
  exec \
  --ephemeral \
  --json \
  --output-last-message <private-run-dir>/final.txt \
  '<prompt>'
```

JSONL、stderr 和最终消息都写在仓库外的私有 run directory，默认权限为 `0700`，不会进入 task branch。

## Git 与写入边界

两种 worker 都遵循同一个 wrapper-owned Git 流程：

1. poller 在认领前检查 CLI、Codex 登录状态和 sandbox 配置。
2. worker 在一次性 clone 里运行，prompt 明确禁止 `git add/commit/push/checkout`。
3. wrapper 用普通文件系统快照比较运行前后差异，不依赖 worker 改过的 Git 配置。
4. 只接受 `work/NNN/` 下的普通文件变化；越界路径、符号链接、secret-shaped 文件名或 HEAD 移动会把任务置为 `stuck`。
5. 合法内容被复制到第二个全新 submission clone，再由 wrapper stage、commit 和 push。

一次性 clone 能隔离常见误操作，但它不是不同 Unix 用户之间的强安全边界。任务来源仍必须是受信任的 Owner / 协作者；不要把公开、未审查的任务直接送入带自动执行权限的 worker。

## 回滚

停止自动 Codex lane 不需要改脚本：

```bash
export PIPELINE_LOCAL_WORKERS=claude
```

已经标记为 `worker: codex` 的 queued / changes_requested 任务会保持原状态，直到另一台启用了 Codex 的机器处理，或人工把 worker 改回 `claude` / `manual`。

## 测试

测试使用本地 bare remote 和 stubbed CLI，不调用真实模型，也不 push GitHub：

```bash
bash tests/test_codex_worker.sh
```

覆盖 Claude 默认兼容、Codex flags、manual lane、缺失 binary、未登录、危险 sandbox、越界写入、runner 失败回滚、HEAD 移动与并发 flock。
