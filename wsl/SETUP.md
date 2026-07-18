# WSL / Linux 端安装（实现端）

实现端需要 git、Python 3，以及至少一个 worker CLI：

- Claude CLI（可执行 `claude`）。自动 Claude lane 还需要可用的 [bubblewrap](https://github.com/containers/bubblewrap)；
- Codex CLI（可执行 `codex`）。

默认 worker 仍是 Claude。Codex 是可选 lane。Claude 的 bubblewrap 配置只在 Claude 任务的认领前检查，不会阻塞 Codex 任务，也不会改变普通交互式 `claude`。

## 1. 安装依赖

Ubuntu / Debian：

```bash
sudo apt-get update
sudo apt-get install -y git python3 bubblewrap
```

确认基础命令可用：

```bash
git --version
python3 --version
claude --version       # 使用 Claude lane 时
bwrap --version        # 使用 Claude lane 时
codex login status     # 使用 Codex lane 时
```

有些 WSL、容器或加固过的 Linux 会禁用 user namespace。poller 不只检查 `bwrap` 是否存在，还会在认领 Claude 任务前实际创建 namespace，验证“宿主根只读 + 指定 bind 可写”。探针失败时任务保持 `queued` / `changes_requested`，不会降级成无隔离执行。

## 2. clone 传送带

```bash
cd ~
git clone git@github.com:<your-account>/pipeline-bus.git
```

把 `<your-account>` 换成实际托管仓库的 GitHub 账户。SSH key 需要具备 push 权限。

## 3. 选择本机 worker

### 只用 Claude（默认）

```bash
export PIPELINE_LOCAL_WORKERS=claude
export PIPELINE_MODEL=                    # 空值使用 Claude CLI 默认模型
export PIPELINE_CLAUDE_BIN=claude
export PIPELINE_CLAUDE_BWRAP_BIN=bwrap
export PIPELINE_CLAUDE_RUN_ROOT="$HOME/.local/state/pipeline-bus/claude-runs"
export PIPELINE_CLAUDE_TIMEOUT_SECONDS=0  # 0 表示不增加 wrapper 超时
```

Claude 自动任务运行在 bubblewrap mount namespace 中：一次性 worker clone 整体只读，只有当前 `work/NNN/` 与仓库外的本次运行目录可写。临时文件、Python bytecode、XDG cache/state 都进入本次运行目录，并在成功、失败、超时或已处理信号后清理。

`PIPELINE_CLAUDE_RUN_ROOT` 必须是 bus checkout 外的绝对路径。poller 会要求它是当前用户拥有的真实目录并设为 `0700`。不要把它指向共享目录、源码 checkout 或需要保留内容的目录。

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

未声明 `worker` 时默认使用 `claude`。完整 Codex 字段、sandbox、运行日志与回滚说明见 [`../docs/CODEX_WORKER.md`](../docs/CODEX_WORKER.md)。

常用 Codex 覆盖：

```bash
export PIPELINE_CODEX_BIN="$HOME/.npm-global/bin/codex"  # 仅 PATH 找不到时需要
export PIPELINE_CODEX_MODEL=""                            # 空值使用 CLI 默认
export PIPELINE_CODEX_REASONING_EFFORT=high
export PIPELINE_CODEX_SANDBOX=workspace-write
export PIPELINE_RUN_ROOT="$HOME/.local/state/pipeline-bus/runs"
```

`PIPELINE_CODEX_SANDBOX` 只接受 `read-only` 或 `workspace-write`；`danger-full-access` 和未知值会在任务认领前被拒绝。Claude 专用的 run root 或 bubblewrap 配置无效时，不会影响已分配给 Codex 的任务。

## 4. 试跑一次

```bash
bash ~/pipeline-bus/wsl/poller.sh
tail ~/pipeline_poller.log
```

有任务时应看到 `claiming task NNN ... worker=...` 和 `submitted for review`。没有可处理任务时静默退出。

Claude lane 可先做一个非破坏性宿主探针：

```bash
bwrap --die-with-parent --new-session --unshare-all --share-net \
  --ro-bind / / --proc /proc --dev /dev -- /bin/true
```

这只确认 namespace 基础能力；poller 自己还会做只读根与可写 bind 的完整认领前探针。

## 5. 挂定时

### 方案 A：cron（推荐 Linux / WSL）

```cron
@reboot sleep 60 && bash ~/pipeline-bus/wsl/poller.sh
*/10 * * * * bash ~/pipeline-bus/wsl/poller.sh
```

poller 会为 cron 补上 `~/.local/bin` 与 `~/.npm-global/bin`。自定义安装位置请使用 `PIPELINE_CLAUDE_BIN`、`PIPELINE_CLAUDE_BWRAP_BIN` 或 `PIPELINE_CODEX_BIN`，不要把用户名硬编码进仓库。

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

## 6. 检验与诊断

- 重启后 1 分钟内，`tail ~/pipeline_poller.log` 应看到新日志。
- push 一张 `state=queued` 的任务单，下一 tick 应由匹配的本机 worker 认领。
- Claude binary、bubblewrap、namespace 探针或 run root 不合格时，Claude 任务必须保持未认领，日志中会有 `preflight:` 原因。
- `worker=codex` 但 Codex 未登录、binary 缺失或本机未启用 codex 时，状态必须保持 `queued` / `changes_requested`。
- Claude 运行结束后，`find "$PIPELINE_CLAUDE_RUN_ROOT" -mindepth 1 -maxdepth 1` 应为空。
- 手动催一轮：`bash ~/pipeline-bus/wsl/poller.sh`。

不要把 Claude/Codex 原始日志、认证文件、prompt transcript 或运行目录复制进 bus repo。详细边界、威胁模型和验证项见 [`../docs/CLAUDE_WORKER_ISOLATION.md`](../docs/CLAUDE_WORKER_ISOLATION.md)。

## 注意与回滚

- poller 幂等并使用单一 `flock`，重复触发不会产生两个 claimant。
- worker 在 disposable clone 中运行；外层 wrapper 验证差异，只提交当前任务的 `work/NNN/`。
- Claude 仍使用 pipeline-only 的 `--dangerously-skip-permissions`，但它只在通过 bubblewrap 探针后启动。任务来源仍必须可信。
- bubblewrap 边界限制写入，不是保密沙盒：为了使用现有 CLI 与认证，宿主文件系统对 Claude 是只读可见的，网络也保持可用。
- 普通交互式 Claude 不经过该 builder，不会被修改设置或重定向 cache。
- Codex JSONL、stderr 和 final message 默认保存在仓库外的 `PIPELINE_RUN_ROOT`，目录权限必须是 `0700`。
- 日志默认 `~/pipeline_poller.log`，可用 `PIPELINE_LOG` 修改。
- BUS 默认 `~/pipeline-bus`，可用 `PIPELINE_BUS` 修改。
- 立即停用 Claude 自动 lane：从 `PIPELINE_LOCAL_WORKERS` 中移除 `claude`（例如只保留 `codex`）。恢复时重新加入即可；不要通过删除 bubblewrap 或放宽隔离来“降级运行”。
