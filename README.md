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

### 实现端（订阅制便宜模型所在机器）

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
| 实现 | 订阅便宜模型 | 50k – 200k |
| 审查 | 中档模型 | 30k – 80k |
| 终审 | Owner（你自己）| 0 token |

2 轮的总成本大约 160k – 560k tokens,**1 美元能跑好几个任务**。这就是把它设计成"小任务流水线"而不是"大工程开发平台"的根本原因 — 每个任务应该是**一个**补丁、**一个**文档、**一个**小工具,不是"重构整个子系统"。

---

## 4. 实战踩坑录（七坑）

每坑格式:**现象 → 根因 → 修法**。这些坑都是这套系统在真实 24/7 跑下来打磨过的,部署前必读。

### 坑① Root 用户不能用 `--dangerously-skip-permissions`

**现象**:审查端的 VPS 是 root 跑的,想偷懒给审查官 `--dangerously-skip-permissions` 全权限,直接被拒绝(`--dangerously-skip-permissions` 不允许在 root 下使用)。

**根因**:Anthropic 客户端出于安全考虑显式禁止 root + 全权限组合(怕你写个 rm -rf / 的 prompt 把根目录清了)。

**修法**:改用 `--allowedTools` 白名单。审查官只需要 Read + 写一个文件,白名单够用且不敢越界:

```bash
claude -p "..." \
  --allowedTools "Read,Glob,Grep,Write,Edit,Bash(git *),Bash(ls *),Bash(cat *),Bash(head *),Bash(wc *),Bash(python3 -c *)"
```

实现端因为通常不是 root,可以保留 `--dangerously-skip-permissions`(poller 只在 bus repo 里干活,任务单来源是封闭的可信通道)。

### 坑② Cron 裸 PATH 找不到 claude

**现象**:把 poller 挂到 crontab,第一次触发直接失败,日志报 `claude: command not found`。手动 `bash poller.sh` 跑得好好的。

**根因**:cron 环境的 `PATH` 很干净,通常只有 `/usr/bin:/bin`,**没有** `~/.local/bin`(claude CLI 的默认安装位置)。登录 shell 里的 `~/.bashrc` 不被 cron 加载,所以手动跑没事 cron 跑就废。

**修法**:`poller.sh` 开头加一行硬编码 PATH:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

比改 crontab 条目更可靠(无论调度器是 cron / systemd-timer / Windows 任务计划,这行都在)。

### 坑③ Claude 跑挂时状态卡死

**现象**:claude 因为网络/额度/神秘原因崩了,poller 没处理,任务永远卡在 `doing` 状态,后面所有任务都排不上去。

**根因**:claude 调用失败时,poller 默认行为是直接退出 — 既不 commit 也不改状态,留下 `doing` 僵尸。

**修法**:poller 把 `claude -p ...` 包在 `|| { ... }` 失败处理里:

```bash
claude -p "$PROMPT" ${MODEL:+--model "$MODEL"} --dangerously-skip-permissions >> "$LOG" 2>&1 || {
  # 状态回滚到认领前(queued 或 changes_requested)
  git checkout -q main
  python3 -c "..."   # 把 state 改回认领前的值
  git add "$sf" && git commit -qm "rollback" && gpush main
  continue            # 跳到下一个任务
}
```

**不留 `doing` 尸体** — 下个 tick 自动重试。连续失败多次再去翻日志。

### 坑④ Round-2 实现端失忆

**现象**:第一轮被打回,poller 重新认领返工时,实现端看不到自己上一轮写过什么、审查官具体批了什么。输出从零开始,根本没改上一轮的问题。

**根因**:第一版 poller 每次都 `git checkout -B task/NNN main` 从 main 新开 branch,丢掉上一轮 `work/NNN/` 下的产出和 `reviews/NNN-r1.md` 批注。task branch 是实现 + 审查的**唯一历史载体**,从 main 重开等于清空记忆。

**修法**:poller 认领时**先查 origin 是否已有该 branch,有就续用**:

```bash
if git fetch -q origin "task/$task" 2>/dev/null; then
  git checkout -qB "task/$task" "origin/task/$task"
else
  git checkout -qB "task/$task" main
fi
```

并把"先读上轮批注"加进 prompt 的 round ≥1 模板里。

### 坑⑤ 双端并发推 main → divergent branch 猝死

**现象**:派单端刚 `git push` 一张新任务单,同一瞬间 poller 也在 `git push` 一个状态变更。两个 push 之一会 fatal:`remote contains work that you do not have locally`。

**根因**:两个 commit 都基于同一个 parent,谁先到谁赢,后到的 push 因为没有 fast-forward 路径直接死。

**修法**:封装一个 `gpush()` 函数,push 失败就 rebase 再 retry:

```bash
gpush() {
  local ref="${1:-main}"
  for _ in 1 2 3; do
    git push -q origin "$ref" && return 0
    git pull -q --rebase origin "$ref" || return 1
  done
  return 1
}
```

3 次 rebase-retry 一般够了(人类派单速度 vs cron 推状态速度,3 拍内必收敛)。**所有 push 都走 gpush,不要直接 `git push`**。

### 坑⑥ Push 被服务端拒 → poller 死亡

**现象**:push 因为 git hook / 大文件限制 / 临时 5xx 失败,poller 没有退路,直接 fatal 退出,**后续任务全堆在本地未 push**。

**根因**:`set -euo pipefail` + 单行 `git push` 没有 fallback。

**修法**:坑⑤的 `gpush` 已经覆盖 — 3 次 rebase-retry 都失败才 return 1,poller 整体因为 `set -e` 退出。下个 tick 会重试(因为状态还没改)。**不要**让 poller 在 push 失败时改状态 — 让它退出就好,把决定权留给下一轮。

### 坑⑦ Git pull 把正在跑的 poller 改坏了

**现象**:`poller.sh` 自己也是 git 跟踪的。`git pull` 拉到新版时,如果正在执行的 poller 实例的 bash 还在 parse 这个文件,会出现"text file busy"或者部分执行新版代码的鬼畜行为。

**根因**:bash 在执行函数体前会先把整个函数定义 parse 完。如果 instance A 拿到的是旧版函数定义,**整个执行周期里都跑的是旧版**,不会被中途换掉。问题是当 A 已经进入 main,但还在执行旧版循环时收到 SIGTERM → 死 → 没有残留。

**修法**:把整个脚本包进 `main()` 函数,只留 `main "$@"; exit` 一行在函数体外:

```bash
main() {
  # ... 全部逻辑 ...
}
main "$@"; exit
```

这样无论怎么 `git pull`,下一次 cron 触发的实例都跑最新版;正在跑的那一票按它 parse 的旧版跑完,不受影响。

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

A: Owner 可以手动拨回状态,下个 tick 重新处理:

```bash
python3 -c "
import json,datetime
d=json.load(open('status/NNN.json'))
d['state']='changes_requested'    # 或 'queued',看想让谁重做
d['updated']=datetime.datetime.now().astimezone().isoformat()
json.dump(d,open('status/NNN.json','w'),ensure_ascii=False)"
git add status/NNN.json && git commit -m "task NNN: unstuck" && git push
```

**先翻 commit 历史**(`git log status/NNN.json`)看任务怎么卡的 — 通常是 race condition 或某个 poller crash 时没回滚。

---

## 6. 仓库结构

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
└── vps/
    ├── reviewer_poll.sh      ← 审查端 cron 脚本（白名单 allowedTools）
    ├── SETUP.md              ← 审查端安装说明 + crontab + 通知 hook
    └── notify.sh.example     ← 空壳通知 hook 模板
```

---

## 7. 上手第一步

1. Fork / clone 这个 repo 到你自己的账户
2. 按 `wsl/SETUP.md` 配实现端,按 `vps/SETUP.md` 配审查端
3. 照 `tasks/000-example.md` 改一改,写成你的第一张真任务单
4. push,等 10 分钟,看 ~`pipeline_poller.log` ~

跑通一个端到端任务就能体会整套机制了。

---

## License

MIT — 拿去用、改卖、嵌入都行,保留版权声明即可。
