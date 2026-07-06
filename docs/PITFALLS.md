# 实战踩坑录（七坑）

> 来自这套系统 24/7 跑下来打磨过的实战记录,每坑格式:**现象 → 根因 → 修法**。
>
> 部署前建议先读一遍,避免在同一处踩两次。最后一节「Owner 手动解卡」是 poller 救不了时的人手兜底,平时用不到、卡住时是唯一出口。

---

## 坑① Root 用户不能用 `--dangerously-skip-permissions`

**现象**:审查端的 VPS 是 root 跑的,想偷懒给审查官 `--dangerously-skip-permissions` 全权限,直接被拒绝(`--dangerously-skip-permissions` 不允许在 root 下使用)。

**根因**:Anthropic 客户端出于安全考虑显式禁止 root + 全权限组合(怕你写个 rm -rf / 的 prompt 把根目录清了)。

**修法**:改用 `--allowedTools` 白名单。审查官只需要 Read + 写一个文件,白名单够用且不敢越界:

```bash
claude -p "..." \
  --allowedTools "Read,Glob,Grep,Write,Edit,Bash(git *),Bash(ls *),Bash(cat *),Bash(head *),Bash(wc *),Bash(python3 -c *)"
```

实现端因为通常不是 root,可以保留 `--dangerously-skip-permissions`(poller 只在 bus repo 里干活,任务单来源是封闭的可信通道)。

## 坑② Cron 裸 PATH 找不到 claude

**现象**:把 poller 挂到 crontab,第一次触发直接失败,日志报 `claude: command not found`。手动 `bash poller.sh` 跑得好好的。

**根因**:cron 环境的 `PATH` 很干净,通常只有 `/usr/bin:/bin`,**没有** `~/.local/bin`(claude CLI 的默认安装位置)。登录 shell 里的 `~/.bashrc` 不被 cron 加载,所以手动跑没事 cron 跑就废。

**修法**:`poller.sh` 开头加一行硬编码 PATH:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

比改 crontab 条目更可靠(无论调度器是 cron / systemd-timer / Windows 任务计划,这行都在)。

## 坑③ Claude 跑挂时状态卡死

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

## 坑④ Round-2 实现端失忆

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

## 坑⑤ 双端并发推 main → divergent branch 猝死

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

## 坑⑥ Push 被服务端拒 → poller 死亡

**现象**:push 因为 git hook / 大文件限制 / 临时 5xx 失败,poller 没有退路,直接 fatal 退出,**后续任务全堆在本地未 push**。

**根因**:`set -euo pipefail` + 单行 `git push` 没有 fallback。

**修法**:坑⑤的 `gpush` 已经覆盖 — 3 次 rebase-retry 都失败才 return 1,poller 整体因为 `set -e` 退出。下个 tick 会重试(因为状态还没改)。**不要**让 poller 在 push 失败时改状态 — 让它退出就好,把决定权留给下一轮。

## 坑⑦ Git pull 把正在跑的 poller 改坏了

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

## Owner 手动解卡（人工干预）

七坑里的所有修法都是**脚本侧自动行为**。但有些情况 poller 自己救不了 — 比如某条状态卡在 `doing` 但 cron 已经停了、你想让 Owner 把 `stuck` 拨回 `changes_requested` 重走一轮、或者想强制让实现端重做 — 这些都要 Owner 手动改 `status/NNN.json`。

**先翻 commit 历史**(`git log status/NNN.json`)看任务怎么卡的 — 通常是 race condition 或某个 poller crash 时没回滚。确认要手动拨回时,直接改 `status/NNN.json` + push:

```bash
python3 -c "
import json,datetime
d=json.load(open('status/NNN.json'))
d['state']='changes_requested'    # 或 'queued',看想让谁重做
d['updated']=datetime.datetime.now().astimezone().isoformat()
json.dump(d,open('status/NNN.json','w'),ensure_ascii=False)"
git add status/NNN.json && git commit -m "task NNN: unstuck" && git push
```

`state` 字段可选值及含义:

- `queued` — 拨回入口,poller 下个 tick 重做
- `changes_requested` — 打回重写(进入第 N+1 轮)
- `review` — 重新走审查(不重写实现)
- `merged` / `stuck` — 终态,谨慎覆盖

改完 push 一下,poller / reviewer 下个 tick 自动接走。
