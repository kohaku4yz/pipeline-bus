# WSL / Linux 端安装（实现端，5 分钟）

前提：实现端机器已经安装 git、Python 3，以及至少一个 worker CLI：

- Claude CLI（可执行 `claude`）；或
- Codex CLI（可执行 `codex`）。

默认仍使用 Claude。Codex 是可选 lane，不配置新变量时旧部署行为不变。

## 1. clone 传送带

```bash
cd ~
git clone git@github.com:<your-account>/pipeline-bus.git
```

把 `<your-account>` 换成实际托管仓库的 GitHub 账户。SSH key 需要具备 push 权限。

## 2. 选择本机 worker

### 只用 Claude（默认）

无需新增配置。Claude 模型仍由 `PIPELINE_MODEL` 覆盖；空值使用 `~/.claude/settings.json` 中的默认。

```bash
export PIPELINE_MODEL=claude-sonnet-4-6   # 可选
```

### 同时启用 Claude 与 Codex

先完成一次 Codex 登录：

```bash
codex login
codex login status
```

然后设置本机能力列表：

```bash
export PIPELINE_LOCAL_WORKERS=claude,codex
```

任务可在 `status/NNN.json` 中声明：

```json
{"task":"100","state":"queued","round":0,"worker":"codex","updated":"..."}
```

未声明 `worker` 时默认使用 `claude`。完整字段、sandbox、运行日志与回滚说明见 [`../docs/CODEX_WORKER.md`](../docs/CODEX_WORKER.md)。

常用 Codex 覆盖：

```bash
export PIPELINE_CODEX_BIN="$HOME/.npm-global/bin/codex"  # 仅 PATH 找不到时需要
export PIPELINE_CODEX_MODEL=""                            # 空值使用 CLI 默认
export PIPELINE_CODEX_REASONING_EFFORT=high
export PIPELINE_CODEX_SANDBOX=workspace-write
export PIPELINE_RUN_ROOT="$HOME/.local/state/pipeline-bus/runs"
```

`PIPELINE_CODEX_SANDBOX` 只接受 `read-only` 或 `workspace-write`；`danger-full-access` 和未知值会在任务认领前被拒绝。

## 3. 试跑一次

```bash
bash ~/pipeline-bus/wsl/poller.sh
tail ~/pipeline_poller.log
```

有任务时应看到 `claiming task NNN ... worker=...` 和 `submitted for review`。没有可处理任务时静默退出。

## 4. 挂定时

### 方案 A：cron（推荐 Linux / WSL）

```cron
@reboot sleep 60 && bash ~/pipeline-bus/wsl/poller.sh
*/10 * * * * bash ~/pipeline-bus/wsl/poller.sh
```

poller 会为 cron 补上 `~/.local/bin` 与 `~/.npm-global/bin`。自定义安装位置请使用 `PIPELINE_CLAUDE_BIN` 或 `PIPELINE_CODEX_BIN`，不要把用户名硬编码进仓库。

### 方案 B：systemd timer

```ini
# ~/.config/systemd/user/pipeline-poller.timer
[Unit]
Description=Pipeline bus poller

[Timer]
OnBootSec=1min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
```

```ini
# ~/.config/systemd/user/pipeline-poller.service
[Service]
ExecStart=/bin/bash -lc 'bash /home/<your-user>/pipeline-bus/wsl/poller.sh'
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now pipeline-poller.timer
```

### 方案 C：Windows 任务计划（WSL 桥接）

任务计划程序 → 新建任务 → 触发器“登录时”与“每 15 分钟” → 操作：

```text
wsl.exe -e bash -lc "bash ~/pipeline-bus/wsl/poller.sh"
```

## 5. 检验

- 重启后 1 分钟内，`tail ~/pipeline_poller.log` 应看到新日志。
- push 一张 `state=queued` 的任务单，下一 tick 应由匹配的本机 worker 认领。
- `worker=codex` 但 Codex 未登录、binary 缺失或本机未启用 codex 时，状态必须保持 queued / changes_requested。
- 手动催一轮：`bash ~/pipeline-bus/wsl/poller.sh`。

## 注意

- poller 幂等并使用单一 `flock`，重复触发不会产生两个 claimant。
- worker 在 disposable clone 中运行；外层 wrapper 验证差异，只提交当前任务的 `work/NNN/`。
- Claude 仍使用 `--dangerously-skip-permissions`。任务来源必须可信；不要把公开未审查的任务直接接入自动 worker。
- Codex JSONL、stderr 和 final message 默认保存在仓库外的 `~/.local/state/pipeline-bus/runs`，目录权限必须是 `0700`。
- 日志默认 `~/pipeline_poller.log`，可用 `PIPELINE_LOG` 修改。
- BUS 默认 `~/pipeline-bus`，可用 `PIPELINE_BUS` 修改。
- 立即停用 Codex：把 `PIPELINE_LOCAL_WORKERS` 改回 `claude`。
