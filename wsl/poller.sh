#!/usr/bin/env bash
# pipeline-bus 实现端 poller — 开机补作业模式
# 挂法见 SETUP.md。幂等: 没活=静默退出,随便多跑。
# v0.1 — 此脚本已加固 7 次实战踩坑,详见 README §4 七坑录。逻辑定型,只接受小修不大改。
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"   # cron 的裸 PATH 没有 claude 的安装位置(七坑②)

# 整体包进 main(): git pull 更新本文件时,已在执行的实例不受影响(bash 需 parse 完函数体才执行)(七坑⑦)
main() {

BUS="${PIPELINE_BUS:-$HOME/pipeline-bus}"
MODEL="${PIPELINE_MODEL:-}"        # 实现工人模型名,SETUP 时填;不设就用本机默认
LOCK=/tmp/pipeline_poller.lock
LOG="${PIPELINE_LOG:-$HOME/pipeline_poller.log}"

exec 9>"$LOCK"; flock -n 9 || exit 0   # 已有 poller 在跑就退,防重入

# push with rebase-retry — 双端并发写 main 的防撞层(七坑⑤⑥)
gpush() {
  local ref="${1:-main}"
  for _ in 1 2 3; do
    git push -q origin "$ref" && return 0
    git pull -q --rebase origin "$ref" || return 1
  done
  return 1
}

cd "$BUS"
git checkout -q main && git pull -q --rebase

for sf in status/*.json; do
  [ -e "$sf" ] || continue
  state=$(python3 -c "import json;print(json.load(open('$sf'))['state'])")
  task=$(python3 -c "import json;print(json.load(open('$sf'))['task'])")
  round=$(python3 -c "import json;print(json.load(open('$sf'))['round'])")

  if [ "$state" = "queued" ] || [ "$state" = "changes_requested" ]; then
    echo "[$(date -Is)] claiming task $task (state=$state round=$round)" >> "$LOG"

    # 认领
    python3 -c "
import json,datetime
d=json.load(open('$sf')); d['state']='doing'; d['updated']=datetime.datetime.now().astimezone().isoformat()
json.dump(d,open('$sf','w'),ensure_ascii=False)"
    git add "$sf" && git commit -qm "claim task $task (doing)" && gpush main

    # 工作 branch: origin 已有就续用(带上 work+reviews 全部历史,七坑④),没有才从 main 新开
    if git fetch -q origin "task/$task" 2>/dev/null; then
      git checkout -qB "task/$task" "origin/task/$task"
    else
      git checkout -qB "task/$task" main
    fi

    # 组 prompt: 任务单 + (如有)review 批注
    PROMPT="你是 pipeline 的实现工程师。先读 PROTOCOL.md 了解协议。然后完成任务单 tasks/${task}-*.md 的全部要求"
    if [ "$state" = "changes_requested" ]; then
      PROMPT="$PROMPT。注意: 这是第$((round+1))轮,上一轮审查未通过,必须先读 reviews/${task}-r${round}.md 的全部批注并逐条修复"
    fi
    PROMPT="$PROMPT。产出按任务单要求放入 work/${task}/。完成后 git add 你的产出并 commit(不要 push,脚本代劳)。"

    claude -p "$PROMPT" ${MODEL:+--model "$MODEL"} --dangerously-skip-permissions >> "$LOG" 2>&1 || {
      echo "[$(date -Is)] claude run FAILED for task $task — rolling state back to $state" >> "$LOG"
      # 状态回滚到认领前,下个 tick 自动重试;不留 doing 尸体(七坑③)
      git checkout -q main
      python3 -c "
import json,datetime
d=json.load(open('$sf')); d['state']='$state'; d['updated']=datetime.datetime.now().astimezone().isoformat()
json.dump(d,open('$sf','w'),ensure_ascii=False)"
      git add "$sf" && git commit -qm "task $task: claude failed, rollback → $state" && gpush main
      continue
    }

    # 交卷: push branch + 状态→review
    git add -A work/ && git diff --cached --quiet || git commit -qm "task $task: implementation (round $((round+1)))"
    gpush "task/$task"
    git checkout -q main && git pull -q --rebase
    python3 -c "
import json,datetime
d=json.load(open('$sf')); d['state']='review'; d['updated']=datetime.datetime.now().astimezone().isoformat()
json.dump(d,open('$sf','w'),ensure_ascii=False)"
    git add "$sf" && git commit -qm "task $task → review" && gpush main
    echo "[$(date -Is)] task $task submitted for review" >> "$LOG"
  fi
done
}
main "$@"; exit
