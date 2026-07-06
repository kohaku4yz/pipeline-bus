# pipeline-bus · 多端・多实例协作 CI/CD

> TL;DR — A pure-git autonomous pipeline: high-throughput models for implementation, mid-tier models for automated review, and frontier models exclusively for final gatekeeping. Zero infrastructure—just a GitHub repo acting as the task bus.

---

## 1. 这是什么

一条**全自动化开发流水线**。Owner 在派单端写一张任务单 → push 到这个 repo → 实现端（高cp值模型）的 poller 自动认领、读单子、产出代码到 `work/NNN/`、push 上自己的 working branch → 审查端（中档模型）的 reviewer 自动对照验收标准批注 → Owner 终审一笔把成品落地到目标 repo。人只需和派单端对接。本implementation为双端双claude code间的协作。

整个系统的**唯一传输层是 GitHub**，没有 webhook、没有消息队列、没有后台进程对进程通信 — 两个 `cron` 脚本（两端各一个）各扫各的状态，靠 git push 来回通讯。

```
┌─────────────┐    push task单 + status    ┌──────────────────┐
│   派单端     │ ────────────────────────▶ │   pipeline-bus   │
│  (Owner)    │                            │   (this repo)    │
└─────────────┘                            └────────┬─────────┘
                                                    │ poll
                                ┌───────────────────┴──────────────────┐
                                ▼                                       ▼
                       ┌─────────────────┐                     ┌─────────────────┐
                       │    实现端       │ ── push branch ──▶  │     审查端      │
                       │  实现工人模型    │                     │   审查官模型     │
                       │  (cron poller)  │ ◀── review批注 ──   │  (cron reviewer)│
                       └─────────────────┘                     └────────┬────────┘
                                                                        │ approved/stuck
                                                                        ▼
                                                               ┌─────────────────┐
                                                               │     Owner       │
                                                               │   终审 + 落地    │
                                                               └─────────────────┘
```

### 适用场景

你的工作流长这样 → 就该用:

- 有**订阅制高cp值模型**（速度够、能干粗活）当实现端
- 有**辅助审查模型**当审查官（静态代码 review + 验收标准对照）
- 有**核心决策模型**只负责**终审 + 写关键决策**（不浪费在常见 bug 上）
- 想把"派活 → 干活 → 审 → 落地"自动化,**不想**自建后端服务或维护消息队列
- 任务单可以写成**可测**的验收标准（每条都要靠"跑一个命令看结果"判定过没过）

不适合的场景:任务需要频繁多人协作、需要 UI、需要跑长任务(数小时级)、单人私事直接干更快的活。

### 角色分工

| 角色 | 谁干 | 干几次 |
|---|---|---|
| **派单端** | 核心决策者| 每任务 1 次（写任务单）|
| **实现端** | 基础实现模型 | 每任务 1-2 轮 |
| **审查端** | 辅助审查模型 | 每任务 1-2 轮 |
| **终审端** | 核心决策者| 每任务 1 次（拿到成品落地）|

---

## 2. 5 分钟快速上手

### 派单端（任意能 push 这个 repo 的机器）

```bash
# 1. 写任务单（参考 tasks/000-example.md）
$EDITOR tasks/100-my-task.md

# 2. 建状态文件
python3 -c "import json,datetime; print(json.dumps({'task':'100','state':'queued','round':0,'updated':datetime.datetime.now().astimezone().isoformat()}))" > status/100.json

# 3. 派单 —— push 到 main = 派单
git add tasks/100-my-task.md status/100.json && git commit -m "task 100: 派单" && git push
```

完事。后面的事全自动。

### 实现端（订阅制高cp值模型所在机器）

```bash
# 1. clone + 装 cron
git clone git@github.com:<your-account>/pipeline-bus.git
crontab -e   # 加一条: */10 * * * * bash ~/pipeline-bus/wsl/poller.sh

# 2. 试跑一次
bash ~/pipeline-bus/wsl/poller.sh && tail ~/pipeline_poller.log
```

不用改 `poller.sh` 一个字 — 模型名从环境变量或本机 `~/.claude/settings.json` 读。

### 审查端（中档模型所在机器，可以和派单端同一台）

```bash
# 1. clone（已经在派单端同台就跳过）
git clone git@github.com:<your-account>/pipeline-bus.git

# 2. 装 cron —— 每10分钟扫一次 review 状态的任务
crontab -e   # 加一条: */10 * * * * bash ~/pipeline-bus/vps/reviewer_poll.sh
```

第一次跑会自动读最新一单 → 审 → 写 `reviews/NNN-r1.md` → 改状态。

---

## 3. 设计要点

### 3.1 为什么纯 git 不用 GitHub API

- **零外部依赖**。不用 `gh` CLI、不用 Personal Access Token、不用 Actions、不用 webhook。cron + bash + git 就够了。两端谁部署在哪都行，只要能 push 这个 repo。
- **自带审计**。`git log` 就是流水账，task 状态变化、实现 diff、审查批注全在历史里。哪天出 bug 不用查 APM，直接翻 commit。
- **自带并发安全**。`git push` 是原子的,冲突由 git 自己解决（rebase-retry 见 §4 坑⑤⑥）。消息队列得自己写防重、防丢失、防乱序。
- **离线也能派活**。任务单 + 状态写本地 commit 一样能进系统。poller 下一 tick 看见就干,网络抖动不算事。

代价:粒度只能到"一个任务",不能在任务内部做流式交互(不需要)。

### 3.2 为什么审查官只给 APPROVED / NEEDS_CHANGES 两档

- **可机械判定**。一行 grep 就能拿到 verdict:`head -1 reviews/... | grep -o 'APPROVED\|NEEDS_CHANGES'`。poller/reviewer 的状态机写起来就一行 if。
- **避免无限扯皮**。"这个实现思路很 elegant 但不够 idiomatic" 这种反馈挂着不动 — 两档强制要么过要么打回(理由明确)。
- **NEEDS_CHANGES 必须附改动方向**。审查官批注里每条 NEEDS 都要求写"在哪、怎么改",不打空炮。

### 3.3 为什么最多 2 轮 review

- **防死循环烧额度**。实现端 + 审查端都是花钱的模型,无限重试能把月度预算耗光。2 轮是经验值:第一轮 catch 明显 bug,第二轮 catch 粗心漏掉的,第三轮以后基本是双方风格之争 — 那种应该人来定。
- **2 轮还过不去** → 进 `stuck` 状态 → 通知渠道叫醒 Owner → 人工看。

### 3.4 成本模型（单任务量级参考）

| 阶段 | 模型档 | token 量级（一次轮）|
|---|---|---|
| 实现 | 订阅制高cp值模型 | 50k – 200k |
| 审查 | 中档模型 | 30k – 80k |
| 终审 | Owner（你自己）| 0 token |

2 轮的总成本大约 160k – 560k tokens,**1 美元能跑好几个任务**。这就是把它设计成"小任务流水线"而不是"大工程开发平台"的根本原因 — 每个任务应该是**一个**补丁、**一个**文档、**一个**小工具,不是"重构整个子系统"。

> 📌 部署前必读:[`docs/PITFALLS.md`](docs/PITFALLS.md) — 七条实战踩坑录,都是这套系统 24/7 跑下来打磨过的。

---

## 4. 仓库结构

```
.
├── README.md                 ← 你正在读的
├── PROTOCOL.md               ← 状态机 / branch 策略 / 落地模式（开发者参考）
├── CLAUDE.md                 ← 实现端工程师须知（给实现模型看的工作手册）
├── LICENSE                   ← MIT
├── tasks/000-example.md      ← 示例任务单
├── wsl/
│   ├── poller.sh             ← 实现端 cron 脚本（已加固 7 次实战踩坑）
│   └── SETUP.md              ← 实现端安装说明
├── vps/
│   ├── reviewer_poll.sh      ← 审查端 cron 脚本（白名单 allowedTools）
│   ├── SETUP.md              ← 审查端安装说明 + crontab + 通知 hook
│   └── notify.sh.example     ← 空壳通知 hook 模板
├── analytics/
│   └── stats.py              ← 零依赖的 per-task 阶段报告脚本
└── docs/
    ├── PITFALLS.md           ← 七坑实战记录
    └── ANALYTICS.md          ← Analytics 详细文档（示例输出 / token 归因 / caveats）
```

---

## 📊 Analytics (optional)

零依赖的 per-task 阶段报告脚本,纯读 `git log` + 本地 Claude session jsonl 重建 `queue → claim → submit → verdict → merged` 时间线。基础用法:

```bash
python3 analytics/stats.py           # terminal table (default)
python3 analytics/stats.py --md      # markdown table for the README
python3 analytics/stats.py --tokens  # append in_tok / out_tok / sess columns
```

示例输出、token 归因、跨主机 caveat 详见 [`docs/ANALYTICS.md`](docs/ANALYTICS.md)。

---

## 5. FAQ

### Q: 怎么换打工模型？

A: **零改动 `poller.sh`**。模型来自两层:
1. 实现端环境变量 `PIPELINE_MODEL`(优先级最高)
2. 实现端 `~/.claude/settings.json` 里的端点 / 模型

poller 调用的是:

```bash
claude -p "$PROMPT" ${MODEL:+--model "$MODEL"}
```

换模型 = 改 `~/.claude/settings.json` 或重启 shell 前 `export PIPELINE_MODEL=...`。审查端模型由 `PIPELINE_REVIEWER_MODEL` 环境变量控制(默认 `sonnet`,见 `vps/SETUP.md` §2),`reviewer_poll.sh` 本身不用改。**换模型时要留意**:审查官需要稳定输出格式(`VERDICT: APPROVED/NEEDS_CHANGES` 首行),先验证新模型能稳定守住这个格式再切换,否则 verdict 解析会 `PARSE_FAIL` → 任务进 `stuck`。

### Q: 实现端离线 / 关机了怎么办？

A: **没事**。任务单 + 状态活在 git 仓库里,poller 只是消费者。实现端下次开机(或下次 cron tick),自动把积压的任务一个一个做完。状态机里 `doing` 是 "实现端在写" 而非 "网络可达",没人等你。

唯一限制:别让一台实现端同时认领同一任务。poller 自带 `flock` 防重入,但如果两台不同机器都跑 poller 就会撞车 — 简单的方案是**只部署一台实现端**。

### Q: 安全模型是什么？

A: **谁能 push 这个 repo = 谁能派单**。这是整套安全模型的全部。

- 任务单(`tasks/NNN-*.md`)和状态(`status/NNN.json`)**只有 Owner 能 push**。否则攻击者可以派"删光生产环境"的活给实现端。
- 实现端用了 `--dangerously-skip-permissions`,等于"如果不可信的人在派单,他能通过 bus 让实现端跑任意 shell"。所以**供应链必须封闭**:Owner 自己 + 可信的协作者。
- 审查端用 `--allowedTools` 白名单,审查官能动的文件/命令范围被钳死 — 即使审查官的 prompt 被人塞了,他也写不到 repo 外的危险地方。

**不适合**做对外开放接任务的市场 — 那种场景请用 GitHub Issues + human review。

### Q: 通知渠道怎么接？

A: 审查端在 `approved` / `stuck` 时会尝试触发通知(让 Owner 知道要终审)。默认留空 — 你可以挂任何通知后端:

```bash
# vps/notify.sh 示例:做成可执行的 hook,审查端调它
#!/usr/bin/env bash
# 可选:接你自己的通知渠道(webhook / telegram bot / 邮件 / Slack / Discord / 飞书 ...)
# 触发场景: review verdict = approved(等终审) 或 stuck(需人工)
msg="$1"
# 例: curl -X POST https://your-webhook.example/... -d "{\"text\":\"$msg\"}"
echo "[notify] $msg" >> /tmp/pipeline_notify.log
```

挂法:把 `vps/SETUP.md` 里 `NOTIFY_CMD` 改成你的 hook 脚本路径。不想通知就保持空。

### Q: 任务卡在奇怪状态怎么办？

A: 先翻 `git log status/NNN.json` 看任务怎么卡的 — 通常是 race condition 或某个 poller crash 时没回滚。典型成因(模型崩、push 撞车、cron 裸 PATH)的自动修法整理在 [`docs/PITFALLS.md`](docs/PITFALLS.md) 坑①~坑⑥,按现象对号入座。

如果 poller 自己救不了(比如 cron 停了、你想强制重做),Owner 手动改 `status/NNN.json` 的命令整理在 [`docs/PITFALLS.md`](docs/PITFALLS.md) 末尾「Owner 手动解卡」一节。

---

## 6. 上手第一步

1. Fork / clone 这个 repo 到你自己的账户
2. 按 `wsl/SETUP.md` 配实现端,按 `vps/SETUP.md` 配审查端
3. 照 `tasks/000-example.md` 改一改,写成你的第一张真任务单
4. push,等 10 分钟,看 ~`pipeline_poller.log` ~

跑通一个端到端任务就能体会整套机制了。

---

## License

MIT — 拿去用、改卖、嵌入都行,保留版权声明即可。
