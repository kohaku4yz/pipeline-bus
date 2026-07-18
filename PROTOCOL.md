# pipeline-bus 协议 v0.2

> 自动化协作流水线协议。三个角色通过一个 GitHub repo 协作：
> **派单端**（Owner）→ **实现端**（poller + 可选 worker CLI）→ **审查端**（reviewer + 审查官模型）→ 终审（Owner）落地。
> GitHub repo 本身是唯一任务传输层，没有额外消息队列。

## 目录

```text
tasks/    任务单 NNN-name.md（Owner 派单时写，push 到 main）
status/   NNN.json 状态机（谁改状态谁 push）
work/     实现端产出（在 branch task/NNN 下，不进 main）
reviews/  审查批注 NNN-rN.md（在 branch task/NNN 下，不进 main）
wsl/      实现端脚本与安装文档
vps/      审查端脚本、安装文档和通知示例
tests/    poller 的 hermetic 回归测试
```

## 状态机（`status/NNN.json`）

```json
{"task":"001","state":"queued","round":0,"worker":"claude","updated":"ISO8601"}
```

```text
queued ─(实现端 poller 认领)→ doing ─(实现端 push task branch)→ review
                                                                   │
                              ┌────────────────────────────────────┼─────────────────────────────┐
                              ▼                                    ▼                             ▼
                          approved                     changes_requested (round+1)                stuck
                       (Owner 终审落地)             (实现端重新认领，最多 2 轮)             (需人工介入)
                              │                                    │
                              ▼                                    └── round ≥ 2 → stuck
                           merged
```

字段含义：

| 字段 | 含义 |
|---|---|
| `task` | 任务编号字符串，必须和文件名 `NNN-*.md` 一致 |
| `state` | 当前状态 |
| `round` | 已完成的审查轮次；0 表示还没审过 |
| `worker` | 可选：`claude`、`codex` 或 `manual`；缺省时由 `PIPELINE_DEFAULT_WORKER` 决定，默认 `claude` |
| `updated` | ISO8601 时间戳，谁改谁更新 |

兼容已有扩展：如果 status 没有顶层 `worker`，poller 也会读取 `roster_override.worker`；两者都不存在时才使用默认 worker。

## Worker assignment 与本机 capability

任务里的 `worker` 是 canonical assignment。本机环境变量 `PIPELINE_LOCAL_WORKERS` 是 capability gate，例如：

```bash
export PIPELINE_LOCAL_WORKERS=claude,codex
```

- assignment=`claude`：Claude binary 可用时认领。
- assignment=`codex`：Codex binary、`codex login status` 和 sandbox preflight 全部通过后才认领。
- assignment=`manual`：永远不自动认领。
- 本机不支持该 assignment：记录 skip，保持 `queued` / `changes_requested`。

未设置 `PIPELINE_LOCAL_WORKERS` 时，只启用 `PIPELINE_DEFAULT_WORKER`；默认仍是单 Claude lane，因此旧部署不受影响。

## 落地模式（任务单里声明）

任务单必须写明 `mode`。

### `mode: patch`

- 适用：实现端不直接写目标仓库。
- 做法：产出放在 `work/NNN/`，并附 `APPLY.md`。
- 当前通用 poller 的自动提交边界就是 `work/NNN/`。

### `mode: direct`

- 适用：实现端对目标仓库有 write 权限。
- 做法：由任务自定义目标仓库 branch 工作流。
- 本模板的 wrapper validation 针对 `patch` 输出布局；direct mode 需要额外扩展，不应绕过现有校验。

## 通知（可选）

- 状态变为 `approved` 或 `stuck` 时，审查端可触发通知 hook。
- 其余状态转换不要求通知。
- `vps/notify.sh` 可接 webhook、IM 或邮件；默认空实现。

## Branch 策略

- `task/NNN` 保存该任务的产出、审查和返工历史。
- `main` 保存任务单、状态与 pipeline 自身代码。
- origin 已有 `task/NNN` 时继续使用；否则从最新 main 创建。
- worker 不负责 Git。wrapper 在 fresh submission clone 中 commit 并 push task branch。

## 实现端的运行与安全边界

- 全机只运行一个逻辑 poller，并由 `/tmp/pipeline_poller.lock` 串行化认领。
- preflight 必须发生在 `state=doing` 之前。
- 每个 worker 在 disposable clone 中运行；prompt 禁止 `git add/commit/push/checkout`。
- wrapper 比较运行前后文件系统快照，拒绝 HEAD 移动、越界路径、符号链接、secret-shaped 路径和未知文件类型。
- 只把验证过的 `work/NNN/` 普通文件复制到第二个 fresh submission clone。
- wrapper-owned Git 使用禁用 global/system config 与 hooks 的执行环境。
- 原始 worker 输出保存在仓库外的私有 run directory，不提交 JSONL、prompt、认证信息或 thread metadata。
- 不使用 `git clean`、`git reset --hard`、`git stash -u` 等 blanket cleanup。
- 这些措施减少误操作与 runner-controlled Git metadata 的风险，但同一 Unix 用户下的 CLI 仍不等于强隔离容器。任务派单权限必须保持封闭可信。

## 状态转换详细规则

### `queued` / `changes_requested` → `doing`

1. 解析 assignment 与本机 capability。
2. 对 Claude 检查 binary；对 Codex检查 binary、登录状态和 sandbox allowlist。
3. preflight 失败：不改状态。
4. preflight 成功：更新为 `doing`，commit 并 push main。

`changes_requested` 的 prompt 必须先读取 `reviews/NNN-r{round}.md` 并逐条修复。

### `doing` → `review`

1. worker 在 disposable clone 中产出文件。
2. wrapper 确认 HEAD 未移动并验证文件系统 delta。
3. 仅将 `work/NNN/` 的合法变化复制到 fresh submission clone。
4. wrapper stage、commit、push `task/NNN`。
5. 回 main 更新 status 为 `review`。

runner 非零退出且没有 unsafe mutation 时，状态恢复为认领前的 `queued` 或 `changes_requested`。HEAD 移动、越界写入或复制验证失败进入 `stuck`，并记录 `[manual-review-required]`。

### `review` → `approved` / `changes_requested` / `stuck`

- 审查官写 `reviews/NNN-rK.md`，第一行必须是 `VERDICT: APPROVED` 或 `VERDICT: NEEDS_CHANGES`。
- 审查端机械解析 verdict，commit + push task branch，再更新 main status。
- NEEDS_CHANGES 增加 round；达到上限后转 `stuck`。

### `approved` → `merged`

- Owner 按 `work/NNN/APPLY.md` 落地并运行验收命令。
- 在目标仓库提交后，把 pipeline status 改为 `merged`。

### `stuck` 的处理

- 检查 `reviews/NNN-r*.md`、task branch 与 poller 私有日志。
- 修复原因后可手动改回 `changes_requested` 或 `queued`。
- 若只是停用某个本地 lane，从 `PIPELINE_LOCAL_WORKERS` 移除它即可；不会留下新的 `doing` 尸体。

## 为什么状态是 JSON 文件而不是数据库

- git diff 能看到完整状态历史。
- cron + Python 标准库即可读取，零服务依赖。
- 状态变更可用 git revert 回滚。
- 人类可以直接编辑修错。

缺点是多台不同机器仍可能同时竞争 main。单机 `flock` 只防本机重入；跨主机主要依赖 push 原子性与 rebase-retry，超高并发需要更强的租约机制。
