#!/usr/bin/env bash
# pipeline-bus implementation poller — one lock, multiple local worker CLIs.
#
# The primary checkout is used only as the control plane. Each task runs in a
# disposable clone; the wrapper validates the resulting filesystem delta and
# copies only work/<task>/ into a fresh submission clone before committing.
set -euo pipefail

export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"

main() {
  local BUS="${PIPELINE_BUS:-$HOME/pipeline-bus}"
  local LOCK="${PIPELINE_LOCK:-/tmp/pipeline_poller.lock}"
  local LOG="${PIPELINE_LOG:-$HOME/pipeline_poller.log}"
  local RUN_ROOT="${PIPELINE_RUN_ROOT:-$HOME/.local/state/pipeline-bus/runs}"
  local CLAUDE_BIN="${PIPELINE_CLAUDE_BIN:-claude}"
  local CLAUDE_MODEL="${PIPELINE_MODEL:-}"
  local CODEX_BIN="${PIPELINE_CODEX_BIN:-codex}"
  local CODEX_MODEL="${PIPELINE_CODEX_MODEL:-}"
  local CODEX_REASONING="${PIPELINE_CODEX_REASONING_EFFORT:-high}"
  local CODEX_SANDBOX="${PIPELINE_CODEX_SANDBOX:-workspace-write}"
  local DEFAULT_WORKER="${PIPELINE_DEFAULT_WORKER:-claude}"
  local LOCAL_WORKERS="${PIPELINE_LOCAL_WORKERS:-$DEFAULT_WORKER}"
  local ORIGIN=""

  mkdir -p "$(dirname "$LOG")"
  touch "$LOG"

  log() {
    printf '[%s] %s\n' "$(date -Is)" "$*" >> "$LOG"
  }

  exec 9>"$LOCK"
  flock -n 9 || exit 0

  command -v python3 >/dev/null 2>&1 || { log "preflight: python3 missing"; return 0; }
  command -v git >/dev/null 2>&1 || { log "preflight: git missing"; return 0; }

  BUS=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$BUS")
  RUN_ROOT=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$RUN_ROOT")
  case "$RUN_ROOT/" in
    "$BUS"/*|"$BUS"/) log "preflight: PIPELINE_RUN_ROOT must be outside PIPELINE_BUS"; return 0 ;;
  esac

  umask 077
  mkdir -p "$RUN_ROOT"
  if ! chmod 700 "$RUN_ROOT" 2>/dev/null; then
    log "preflight: cannot secure PIPELINE_RUN_ROOT"
    return 0
  fi
  [ "$(stat -c '%a' "$RUN_ROOT" 2>/dev/null || true)" = "700" ] || {
    log "preflight: PIPELINE_RUN_ROOT must have mode 0700"
    return 0
  }

  trusted_git() {
    local repo="$1"; shift
    env -i \
      PATH="$PATH" HOME="${HOME:-/tmp}" LANG="${LANG:-C.UTF-8}" \
      ${SSH_AUTH_SOCK:+SSH_AUTH_SOCK="$SSH_AUTH_SOCK"} \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      GIT_TERMINAL_PROMPT=0 \
      git -C "$repo" -c core.hooksPath=/dev/null -c credential.helper= \
      -c user.name="${PIPELINE_GIT_NAME:-pipeline-bus}" \
      -c user.email="${PIPELINE_GIT_EMAIL:-pipeline-bus@localhost}" "$@"
  }

  trusted_clone() {
    local dest="$1"
    env -i \
      PATH="$PATH" HOME="${HOME:-/tmp}" LANG="${LANG:-C.UTF-8}" \
      ${SSH_AUTH_SOCK:+SSH_AUTH_SOCK="$SSH_AUTH_SOCK"} \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      GIT_TERMINAL_PROMPT=0 \
      git clone -q -c core.hooksPath=/dev/null -c credential.helper= \
      --no-local --no-hardlinks "$ORIGIN" "$dest"
  }

  gpush() {
    local repo="$1" refspec="$2" remote_ref="${2##*:}"
    local attempt
    for attempt in 1 2 3; do
      trusted_git "$repo" push -q "$ORIGIN" "$refspec" && return 0
      trusted_git "$repo" fetch -q "$ORIGIN" "$remote_ref" || return 1
      trusted_git "$repo" rebase "FETCH_HEAD" || return 1
    done
    return 1
  }

  worker_from_status() {
    python3 - "$1" "$DEFAULT_WORKER" <<'PY'
import json, sys
status = json.load(open(sys.argv[1]))
worker = status.get("worker") or (status.get("roster_override") or {}).get("worker") or sys.argv[2]
print(worker)
PY
  }

  local_can_run() {
    local wanted="$1"
    python3 - "$wanted" "$LOCAL_WORKERS" <<'PY'
import sys
wanted, raw = sys.argv[1:]
values = [x.strip() for x in raw.split(",")]
valid = {"claude", "codex", "manual"}
if not values or any(not x or x not in valid for x in values):
    raise SystemExit(2)
print("yes" if wanted in values else "no")
PY
  }

  preflight_worker() {
    local worker="$1"
    case "$worker" in
      claude)
        command -v "$CLAUDE_BIN" >/dev/null 2>&1 || { log "preflight: Claude CLI unavailable"; return 1; }
        ;;
      codex)
        case "$CODEX_SANDBOX" in
          read-only|workspace-write) ;;
          *) log "preflight: invalid Codex sandbox '$CODEX_SANDBOX'"; return 1 ;;
        esac
        command -v "$CODEX_BIN" >/dev/null 2>&1 || { log "preflight: Codex CLI unavailable"; return 1; }
        "$CODEX_BIN" login status >/dev/null 2>&1 || { log "preflight: Codex CLI is not logged in"; return 1; }
        ;;
      manual)
        return 2
        ;;
      *)
        log "preflight: unknown worker '$worker'"
        return 1
        ;;
    esac
  }

  update_status() {
    local sf="$1" new_state="$2" message="$3"
    trusted_git "$BUS" checkout -q main
    trusted_git "$BUS" pull -q --rebase "$ORIGIN" main
    python3 - "$sf" "$new_state" <<'PY'
import datetime, json, sys
path, state = sys.argv[1:]
data = json.load(open(path))
data["state"] = state
data["updated"] = datetime.datetime.now().astimezone().isoformat()
with open(path, "w") as f:
    json.dump(data, f, ensure_ascii=False)
PY
    trusted_git "$BUS" add -- "$sf"
    trusted_git "$BUS" commit -qm "$message"
    gpush "$BUS" HEAD:main
  }

  snapshot_tree() {
    local root="$1" output="$2"
    python3 - "$root" "$output" <<'PY'
import hashlib, json, os, stat, sys
root, output = map(os.path.realpath, sys.argv[1:])
items = {}
for current, dirs, files in os.walk(root, topdown=True, followlinks=False):
    rel_current = os.path.relpath(current, root)
    if rel_current == ".":
        dirs[:] = [d for d in dirs if d != ".git"]
    for name in list(dirs) + files:
        path = os.path.join(current, name)
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        if rel == ".git" or rel.startswith(".git/"):
            continue
        st = os.lstat(path)
        if stat.S_ISLNK(st.st_mode):
            items[rel] = {"type": "symlink", "target": os.readlink(path), "mode": stat.S_IMODE(st.st_mode)}
        elif stat.S_ISREG(st.st_mode):
            h = hashlib.sha256()
            with open(path, "rb") as f:
                for chunk in iter(lambda: f.read(1024 * 1024), b""):
                    h.update(chunk)
            items[rel] = {"type": "file", "sha256": h.hexdigest(), "mode": stat.S_IMODE(st.st_mode)}
        elif stat.S_ISDIR(st.st_mode):
            items[rel] = {"type": "dir", "mode": stat.S_IMODE(st.st_mode)}
        else:
            items[rel] = {"type": "other", "mode": stat.S_IMODE(st.st_mode)}
with open(output, "w") as f:
    json.dump(items, f, sort_keys=True)
PY
  }

  resolve_head_without_git() {
    python3 - "$1" <<'PY'
import os, sys
root = os.path.realpath(sys.argv[1])
gitdir = os.path.join(root, ".git")
head = open(os.path.join(gitdir, "HEAD")).read().strip()
if not head.startswith("ref: "):
    print(head)
    raise SystemExit
ref = head[5:]
loose = os.path.join(gitdir, *ref.split("/"))
if os.path.isfile(loose):
    print(open(loose).read().strip())
    raise SystemExit
packed = os.path.join(gitdir, "packed-refs")
if os.path.isfile(packed):
    for line in open(packed):
        if line.startswith("#") or line.startswith("^"):
            continue
        oid, name = line.rstrip().split(" ", 1)
        if name == ref:
            print(oid)
            raise SystemExit
raise SystemExit(1)
PY
  }

  validate_delta() {
    local before="$1" after="$2" task="$3" output="$4"
    python3 - "$before" "$after" "$task" "$output" <<'PY'
import json, os, re, sys
before_path, after_path, task, output = sys.argv[1:]
before = json.load(open(before_path)); after = json.load(open(after_path))
changed = sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))
root = f"work/{task}/"
secret = re.compile(r"(^|/)(\.env($|\.)|id_(rsa|ed25519)($|\.)|[^/]*(secret|token|credential|auth)[^/]*)", re.I)
errors = []
files = []
for path in changed:
    if path in {"work", f"work/{task}"}:
        entry = after.get(path)
        if entry and entry.get("type") != "dir":
            errors.append(f"unsupported-type:{path}")
        continue
    if not path.startswith(root):
        errors.append(f"out-of-scope:{path}")
        continue
    entry = after.get(path)
    if entry and entry.get("type") == "symlink":
        errors.append(f"symlink:{path}")
        continue
    if entry and entry.get("type") not in {"file", "dir"}:
        errors.append(f"unsupported-type:{path}")
        continue
    if secret.search(path):
        errors.append(f"secret-shaped:{path}")
        continue
    files.append(path)
with open(output, "w") as f:
    json.dump({"changed": changed, "validated": files, "errors": errors}, f)
if errors:
    print(";".join(errors))
    raise SystemExit(1)
if not changed:
    print("no worker output")
    raise SystemExit(1)
PY
  }

  copy_validated_delta() {
    local source="$1" dest="$2" before="$3" after="$4" task="$5"
    python3 - "$source" "$dest" "$before" "$after" "$task" <<'PY'
import json, os, shutil, stat, sys
source, dest, before_path, after_path, task = sys.argv[1:]
before = json.load(open(before_path)); after = json.load(open(after_path))
root = f"work/{task}/"
changed = sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))
for rel in changed:
    if rel in {"work", f"work/{task}"}:
        continue
    if not rel.startswith(root):
        raise SystemExit(f"out-of-scope:{rel}")
    src = os.path.join(source, *rel.split("/"))
    dst = os.path.join(dest, *rel.split("/"))
    entry = after.get(rel)
    if entry is None:
        if os.path.isdir(dst) and not os.path.islink(dst):
            shutil.rmtree(dst)
        elif os.path.lexists(dst):
            os.unlink(dst)
        continue
    if entry["type"] == "dir":
        os.makedirs(dst, exist_ok=True)
        os.chmod(dst, entry["mode"])
        continue
    if entry["type"] != "file":
        raise SystemExit(f"unsupported-type:{rel}")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)
    os.chmod(dst, entry["mode"])
PY
  }

  build_prompt() {
    local task="$1" prior_state="$2" round="$3"
    local prompt
    prompt="你是 pipeline-bus 的实现工程师。先读 PROTOCOL.md，再完成 tasks/${task}-*.md。只允许修改 work/${task}/ 下面的文件。不要运行 git add、git commit、git push、git checkout 或修改 .git；提交由外层脚本负责。"
    if [ "$prior_state" = "changes_requested" ]; then
      prompt="$prompt 这是第$((round + 1))轮；先完整阅读 reviews/${task}-r${round}.md 并逐条修复。"
    fi
    printf '%s\n' "$prompt"
  }

  run_claude() {
    local wt="$1" prompt="$2" run_dir="$3"
    local -a cmd=("$CLAUDE_BIN" -p "$prompt")
    [ -z "$CLAUDE_MODEL" ] || cmd+=(--model "$CLAUDE_MODEL")
    cmd+=(--dangerously-skip-permissions)
    (cd "$wt" && env -u PIPELINE_BUS -u PIPELINE_RUN_ROOT "${cmd[@]}") \
      >"$run_dir/claude.stdout.log" 2>"$run_dir/claude.stderr.log"
  }

  run_codex() {
    local wt="$1" prompt="$2" run_dir="$3"
    local -a cmd=("$CODEX_BIN" -a never --sandbox "$CODEX_SANDBOX" -C "$wt")
    [ -z "$CODEX_MODEL" ] || cmd+=(-m "$CODEX_MODEL")
    cmd+=(-c "model_reasoning_effort=$CODEX_REASONING" exec --ephemeral --json \
      --output-last-message "$run_dir/final.txt" "$prompt")
    env -u PIPELINE_BUS -u PIPELINE_RUN_ROOT "${cmd[@]}" \
      >"$run_dir/codex.jsonl" 2>"$run_dir/codex.stderr.log"
  }

  cd "$BUS"
  ORIGIN=$(trusted_git "$BUS" config --get remote.origin.url 2>/dev/null || true)
  [ -n "$ORIGIN" ] || { log "preflight: origin missing"; return 0; }
  trusted_git "$BUS" checkout -q main
  trusted_git "$BUS" pull -q --rebase "$ORIGIN" main

  local sf state task round worker can_run preflight_rc
  local run_dir wt submit before after delta base_head after_head prompt runner_rc
  for sf in status/*.json; do
    [ -e "$sf" ] || continue
    state=$(python3 -c "import json; print(json.load(open('$sf'))['state'])")
    [ "$state" = "queued" ] || [ "$state" = "changes_requested" ] || continue
    task=$(python3 -c "import json; print(json.load(open('$sf'))['task'])")
    round=$(python3 -c "import json; print(json.load(open('$sf'))['round'])")
    worker=$(worker_from_status "$sf")

    if ! can_run=$(local_can_run "$worker" 2>/dev/null); then
      log "task $task: invalid PIPELINE_LOCAL_WORKERS='$LOCAL_WORKERS'; skip"
      continue
    fi
    if [ "$worker" = "manual" ]; then
      log "task $task: manual worker lane; skip"
      continue
    fi
    if [ "$can_run" != "yes" ]; then
      log "task $task: worker=$worker is not enabled locally; skip"
      continue
    fi

    set +e
    preflight_worker "$worker"
    preflight_rc=$?
    set -e
    [ "$preflight_rc" -eq 0 ] || continue

    log "claiming task $task (state=$state round=$round worker=$worker)"
    update_status "$sf" doing "claim task $task (doing, worker=$worker)"

    run_dir="$RUN_ROOT/${task}-$(date +%Y%m%dT%H%M%S)-$$"
    mkdir -m 700 "$run_dir"
    wt="$run_dir/worker"
    submit="$run_dir/submission"
    before="$run_dir/before.json"
    after="$run_dir/after.json"
    delta="$run_dir/delta.json"

    if ! trusted_clone "$wt"; then
      log "task $task: worker clone failed"
      update_status "$sf" "$state" "task $task: clone failed, rollback to $state"
      continue
    fi
    if trusted_git "$wt" fetch -q "$ORIGIN" "task/$task" 2>/dev/null; then
      trusted_git "$wt" checkout -qB "task/$task" FETCH_HEAD
    else
      trusted_git "$wt" checkout -qB "task/$task" main
    fi

    base_head=$(resolve_head_without_git "$wt")
    snapshot_tree "$wt" "$before"
    prompt=$(build_prompt "$task" "$state" "$round")

    set +e
    if [ "$worker" = "claude" ]; then
      run_claude "$wt" "$prompt" "$run_dir"
      runner_rc=$?
    else
      run_codex "$wt" "$prompt" "$run_dir"
      runner_rc=$?
    fi
    set -e

    after_head=$(resolve_head_without_git "$wt" 2>/dev/null || printf 'invalid')
    snapshot_tree "$wt" "$after"

    if [ "$after_head" != "$base_head" ]; then
      log "task $task: worker moved HEAD; marking stuck [manual-review-required]"
      update_status "$sf" stuck "task $task: unsafe worker Git mutation"
      continue
    fi

    if [ "$runner_rc" -ne 0 ]; then
      if validate_delta "$before" "$after" "$task" "$delta" >/dev/null 2>&1; then
        log "task $task: worker exited $runner_rc after in-scope edits; rollback to $state"
      else
        log "task $task: worker exited $runner_rc; rollback to $state"
      fi
      update_status "$sf" "$state" "task $task: worker failed, rollback to $state"
      continue
    fi

    if ! reason=$(validate_delta "$before" "$after" "$task" "$delta" 2>&1); then
      log "task $task: unsafe output ($reason); marking stuck [manual-review-required]"
      update_status "$sf" stuck "task $task: unsafe worker output"
      continue
    fi

    if ! trusted_clone "$submit"; then
      log "task $task: submission clone failed; rollback to $state"
      update_status "$sf" "$state" "task $task: submission clone failed, rollback to $state"
      continue
    fi
    if trusted_git "$submit" fetch -q "$ORIGIN" "task/$task" 2>/dev/null; then
      trusted_git "$submit" checkout -qB "task/$task" FETCH_HEAD
    else
      trusted_git "$submit" checkout -qB "task/$task" main
    fi

    if ! copy_validated_delta "$wt" "$submit" "$before" "$after" "$task"; then
      log "task $task: validated copy failed; marking stuck [manual-review-required]"
      update_status "$sf" stuck "task $task: validated copy failed"
      continue
    fi

    trusted_git "$submit" add -A -- "work/$task"
    if trusted_git "$submit" diff --cached --quiet; then
      log "task $task: no staged output after validated copy; rollback to $state"
      update_status "$sf" "$state" "task $task: empty output, rollback to $state"
      continue
    fi
    trusted_git "$submit" commit -qm "task $task: implementation (round $((round + 1)), worker=$worker)"
    if ! gpush "$submit" "HEAD:task/$task"; then
      log "task $task: task branch push failed; rollback to $state"
      update_status "$sf" "$state" "task $task: push failed, rollback to $state"
      continue
    fi

    update_status "$sf" review "task $task -> review"
    log "task $task submitted for review (worker=$worker)"
  done
}

main "$@"
