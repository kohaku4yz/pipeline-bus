# pipeline-bus 协议 v0.1

> 自动化协作流水线协议。三个角色通过一个 GitHub repo 协作：
> **派单端**(Owner) → **实现端**(poller + 实现工人模型) → **审查端**(reviewer + 审查官模型) → 终审(Owner)落地。
> GitHub repo 本身是**唯一任务传输层**，没有别的消息队列。

## 目录

```
tasks/    任务单 NNN-name.md（Owner 派单时写，push 到 main）
status/   NNN.json 状态机（谁改状态谁 push）
work/     实现端的产出（在 branch task/NNN 下，不进 main）
reviews/  审查官的批注 NNN-rN.md（在 branch task/NNN 下，不进 main）
wsl/      实现端脚本（poller.sh + SETUP.md）
vps/      审查端脚本（reviewer_poll.sh + SETUP.md + notify 示例）
```

## 状态机（`status/NNN.json`）

```json
{"task": "001", "state": "queued", "round": 0, "updated": "ISO8601"}
```

```
queued ─(实现端 poller 认领)→ doing ─(实现端 push task branch)→ review
                                                                   │
                              ┌────────────────────────────────────┼─────────────────────────────┐
                              ▼                                    ▼                             ▼
                          approved                     changes_requested (round+1)                stuck
                       (Owner 终审落地)             (实现端重新认领,最多 2 轮)             (≥ 2 轮未过,需人工)
                              │                                    │
                              ▼                                    └── round ≥ 2 → stuck
                           merged
                       (Owner 改状态,任务完结)
```

字段含义:

| 字段 | 含义 |
|---|---|
| `task` | 任务编号字符串(必须和文件名 `NNN-*.md` 一致) |
| `state` | 当前状态(取值见上图) |
| `round` | 已完成的审查轮次;0 表示还没审过 |
| `updated` | ISO8601 时间戳,谁改谁更新 |

## 落地模式(任务单里声明)

任务单第一行必须写明 `mode`,实现端据此决定能否直接 push 到目标仓库。

### `mode: patch`

- **适用**: 目标仓库 Owner 没有 WSL 写权限(如别人账户下的仓库)
- **做法**: 实现端把产出文件放 `work/NNN/`,**附 `APPLY.md`** 写明落地步骤。终审端按 APPLY.md 在 VPS 或本地手动 cp / git apply
- **为何不直接帮 push**: 凭据是别人的,跨账户 clone + push 走 OAuth flow 又重。发 patch 更轻

### `mode: direct`

- **适用**: 目标仓库在你能 push 的账户下
- **做法**: 实现端**直接 clone 目标仓库开 branch 干活**,产出进 target repo 的 `task/NNN` branch。终审落地是直接 merge
- **注意**: 本模板只示范 `patch` 模式的输出布局;`direct` 模式需要实现端有目标 repo 的 write 权限,自行扩展

## 通知(可选)

- 状态变为 `approved` 或 `stuck` 时,审查端会触发通知 hook,**召唤 Owner** 来终审或介入
- 其余状态转换全自动,**不需要通知**
- 通知通过 `vps/notify.sh` 模板挂载,你可以接到任何 webhook / IM / 邮件 — 默认留空,什么都不做

## Branch 策略

- `task/NNN` 是任务的**全部工作历史**: 实现端产出 + 审查官批注 + 多轮返工,**都住在这条 branch 上**
- `main` 只放任务单和状态 — 实现产出的代码**不 merge 回 main**,终审端验证通过后由 Owner **直接落地到目标仓库**(而不是 merge 回 pipeline-bus main)
- poller 认领规则: origin 已有 `task/NNN` → 续用(带完整 work + reviews 历史);没有 → 从 main 新开

## 轮次与安全

- review 最多 2 轮 → 第 3 轮还不过,直接进 `stuck` 叫人
- 实现端**只在 branch `task/NNN` 上工作**,禁止直接 push `main`(status 文件除外)
- 审查端只对 diff 做**静态审查**,**不执行 `work/NNN/` 里的代码** — 这是防危险产物跑起来的硬约束
- 安全模型: **谁能 push `tasks/` 和 `status/`,谁能派单**。这套流水线的实现端用了 `--dangerously-skip-permissions`,供应链必须封闭(Owner + 可信协作者)。要对外开放接任务请用别的工作流

## 状态转换详细规则

### `queued` → `doing`(实现端自动)

```bash
git checkout main && git pull --rebase
# 读 status/NNN.json,确认 state=queued 且 round=0
# python3 改 state=doing,updated=now
git add status/NNN.json
git commit -m "claim task NNN (doing)"
gpush main   # push 走 rebase-retry(见 wsl/poller.sh gpush())
```

### `changes_requested` → `doing`(实现端自动,round >= 1)

同上,但 round ≥ 1 时 prompt 必须附一句"**先读 reviews/NNN-r{prev_round}.md 全部批注并逐条修复**"。poller 也要从 origin `task/NNN` 续用 branch,保证 work + reviews 历史可见(详见 wsl/poller.sh)。

### `doing` → `review`(实现端自动)

```bash
# claude -p "$PROMPT" 跑通后:
git add -A work/
git diff --cached --quiet || git commit -m "task NNN: implementation (round K)"
gpush task/NNN
git checkout main && git pull --rebase
# python3 改 state=review,updated=now,round 不变
git add status/NNN.json
git commit -m "task NNN → review"
gpush main
```

### `review` → `approved` / `changes_requested` / `stuck`(审查端自动)

- 审查官写 `reviews/NNN-rK.md`,**第一行必须是 `VERDICT: APPROVED` 或 `VERDICT: NEEDS_CHANGES`**
- 审查端用 `head -1 | grep -o 'APPROVED\|NEEDS_CHANGES'` 机械判定
- 判定后 commit + push `task/NNN` branch(批注住进这条 branch)
- 然后回到 main 改 status,round +1 如果是 NEEDS_CHANGES 且 round < MAX
- 触发通知(仅当新状态 = approved 或 stuck)

### `approved` → `merged`(Owner 手动)

- Owner 读 `work/NNN/APPLY.md` 在目标仓库跑落地步骤
- 实测(`bash -n`, `python3 -c '...'` 等任务单验收命令)
- 在目标 repo 提交并 push
- 回到 pipeline-bus 改 `status/NNN.json` 的 `state=merged`

### `stuck` 的 Owner 解法

- 翻 `reviews/NNN-r*.md` 历史 + `git log status/NNN.json` 看僵在哪一步
- 手动改 `state='changes_requested'` 或 `state='queued'`,push — 下个 tick 重新开始
- 要么就承认失败,改 task 单,然后手动把目标 repo 的产出落地

## 为什么状态是 JSON 文件而不是 SQLite / 数据库

- git diff 看得到状态变更历史(每次 state 变就是一次 commit)
- cron 脚本读 JSON 直接 `python3 -c`,零依赖
- 状态变更天然可回滚(`git revert` 即可)
- 人类也能直接编辑修错(`vim status/001.json`)

缺点: 高并发多个 poller 同时改不同 status 会撞,**靠 gpush rebase-retry 缓解**;真要多实例同时跑请加更强锁。
