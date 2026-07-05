#!/usr/bin/env bash
# pipeline-bus 审查端 poller — cron 每 10 分钟: 发现 state==review 的任务就派审查官审查
# 挂法见 SETUP.md。allowedTools 白名单替代 --dangerously-skip-permissions(七坑①),因为审查端常以 root 跑
# v0.1 — 逻辑定型,小修可,大改请先读 README §4 七坑录
set -euo pipefail

BUS="${PIPELINE_BUS:-/opt/pipeline-bus}"
LOCK=/tmp/pipeline_reviewer.lock
LOG="${PIPELINE_REVIEWER_LOG:-/tmp/pipeline_reviewer.log}"
NOTIFY_CMD="${PIPELINE_NOTIFY:-}"    # 可选: 已批准/卡死时调用的通知 hook(默认空=不通知)
MAX_ROUNDS=2
REVIEWER_MODEL="${PIPELINE_REVIEWER_MODEL:-sonnet}"

exec 9>"$LOCK"; flock -n 9 || exit 0

# 整体包进 main(): git pull 更新本文件时,已在执行的实例不受影响(七坑⑦)
main() {

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
  [ "$state" = "review" ] || continue
  task=$(python3 -c "import json;print(json.load(open('$sf'))['task'])")
  round=$(python3 -c "import json;print(json.load(open('$sf'))['round'])")
  r=$((round + 1))
  echo "[$(date -Is)] reviewing task $task round $r" >> "$LOG"

  git fetch -q origin "task/$task"
  git checkout -q "task/$task" 2>/dev/null || git checkout -qb "task/$task" "origin/task/$task"
  git reset -q --hard "origin/task/$task"

  claude -p "你是 pipeline 审查官(参考 PROTOCOL.md)。审查 task ${task} 第 ${r} 轮实现:
1. 读 tasks/${task}-*.md 的需求与验收标准
2. 看 diff: git diff main...HEAD -- work/ ; 并直接阅读 work/${task}/ 下的产出文件
3. 只做静态审查,不要执行 work/ 里的任何代码;可以运行 git/ls/cat 类只读命令
4. 逐条对照验收标准,检查正确性 bug、漏项、风格与任务单的一致性
5. 把审查报告写入 reviews/${task}-r${r}.md —— 第一行必须是 'VERDICT: APPROVED' 或 'VERDICT: NEEDS_CHANGES',之后是逐条批注(NEEDS_CHANGES 时每条给出文件位置和该怎么改)
6. git add reviews/${task}-r${r}.md 并 commit,不要 push" \
    --model "$REVIEWER_MODEL" --allowedTools "Read,Glob,Grep,Write,Edit,Bash(git *),Bash(ls *),Bash(cat *),Bash(head *),Bash(wc *),Bash(python3 -c *)" >> "$LOG" 2>&1 || {
      echo "[$(date -Is)] reviewer claude FAILED task $task" >> "$LOG"; git checkout -q main; continue; }

  verdict=$(head -1 "reviews/${task}-r${r}.md" 2>/dev/null | grep -o 'APPROVED\|NEEDS_CHANGES' || echo PARSE_FAIL)
  gpush "task/$task"
  git checkout -q main && git pull -q --rebase

  if [ "$verdict" = "APPROVED" ]; then new_state="approved"
  elif [ "$verdict" = "NEEDS_CHANGES" ] && [ "$r" -ge "$MAX_ROUNDS" ]; then new_state="stuck"
  elif [ "$verdict" = "NEEDS_CHANGES" ]; then new_state="changes_requested"
  else new_state="stuck"; fi

  python3 -c "
import json,datetime
d=json.load(open('$sf')); d['state']='$new_state'; d['round']=$r
d['updated']=datetime.datetime.now().astimezone().isoformat()
json.dump(d,open('$sf','w'),ensure_ascii=False)"
  git add "$sf" && git commit -qm "task $task: review r$r → $new_state" && gpush main
  echo "[$(date -Is)] task $task → $new_state" >> "$LOG"

  # 终态通知(可选): PIPELINE_NOTIFY 指向的脚本会被传入一句话描述
  if [ -n "$NOTIFY_CMD" ] && { [ "$new_state" = "approved" ] || [ "$new_state" = "stuck" ]; }; then
    "$NOTIFY_CMD" "[pipeline-bus] task ${task} 状态=${new_state}(第 ${r} 轮审查)。Owner 终审: git fetch && git diff main...origin/task/${task},读 reviews/${task}-r${r}.md;approved 则按 work/${task}/APPLY.md 落地到目标仓库并改 status=merged,stuck 则人工定夺。" || true
  fi
done
}
main "$@"; exit
