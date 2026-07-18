#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
POLLER="$REPO_ROOT/wsl/poller.sh"
TMP_ROOT=$(mktemp -d -t pipeline-worker-test-XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT

pass() { printf 'PASS %s\n' "$1"; }
fail() { printf 'FAIL %s: %s\n' "$1" "$2" >&2; exit 1; }

state_of() {
  git --git-dir="$1/remote.git" show main:status/001.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])'
}

new_fixture() {
  local name="$1" worker="${2:-}"
  FIX="$TMP_ROOT/$name"
  mkdir -p "$FIX"
  git init -q --bare "$FIX/remote.git"
  git clone -q "$FIX/remote.git" "$FIX/seed"
  (
    cd "$FIX/seed"
    git config user.name test
    git config user.email test@example.invalid
    git checkout -qb main
    mkdir -p tasks status work reviews wsl analytics
    printf '# protocol\n' > PROTOCOL.md
    printf '# task\n\nmode: patch\n' > tasks/001-test.md
    printf 'print("ok")\n' > analytics/sample.py
    if [ -n "$worker" ]; then
      printf '{"task":"001","state":"queued","round":0,"worker":"%s","updated":"x"}\n' "$worker" > status/001.json
    else
      printf '{"task":"001","state":"queued","round":0,"updated":"x"}\n' > status/001.json
    fi
    cp "$POLLER" wsl/poller.sh
    git add .
    git commit -qm init
    git push -q -u origin main
    git --git-dir="$FIX/remote.git" symbolic-ref HEAD refs/heads/main
  )
  git clone -q "$FIX/remote.git" "$FIX/bus"
  mkdir -p "$FIX/bin" "$FIX/runs" "$FIX/claude-runs"
  chmod 700 "$FIX/runs" "$FIX/claude-runs"
  TRACE="$FIX/trace"
  LOG="$FIX/poller.log"
  LOCK="$FIX/poller.lock"
}

install_claude_stub() {
  cat > "$FIX/bin/claude" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --version ]; then
  printf 'claude test 1.0\n'
  exit 0
fi
if [ -n "${STUB_TRACE:-}" ] && printf 'CLAUDE ' >> "$STUB_TRACE" 2>/dev/null; then
  printf '%q ' "$@" >> "$STUB_TRACE"; printf '\n' >> "$STUB_TRACE"
fi
case "${STUB_BEHAVIOR:-success}" in
  success) mkdir -p work/001; printf 'ok\n' > work/001/result.txt ;;
  outscope) printf 'bad\n' > README.md ;;
  fail) mkdir -p work/001; printf 'partial\n' > work/001/result.txt; exit 7 ;;
  slow) sleep 2; mkdir -p work/001; printf 'ok\n' > work/001/result.txt ;;
  gitmove) git config user.name bad; git config user.email bad@example.invalid; mkdir -p work/001; echo bad > work/001/result.txt; git add .; git commit -qm bad ;;
  bytecode) mkdir -p work/001/__pycache__; printf evil > work/001/evil.pyc; printf evil > work/001/__pycache__/evil.cpython-313.pyc ;;
  pycompile)
    python3 -m py_compile analytics/sample.py
    find "$PYTHONPYCACHEPREFIX" -type f -name '*.pyc' -print -quit | grep -q .
    if find . -type f \( -name '*.pyc' -o -path '*/__pycache__/*' \) -print -quit | grep -q .; then exit 91; fi
    mkdir -p work/001; printf 'pycache-external\n' > work/001/result.txt
    ;;
  boundary)
    mkdir -p work/001
    root=blocked; other=blocked
    if printf escape > README.md 2>/dev/null; then root=writable; fi
    if mkdir -p work/other-task 2>/dev/null; then other=writable; fi
    printf '%s %s\n' "$root" "$other" > work/001/result.txt
    ;;
  gitboundary)
    mkdir -p work/001
    printf change > work/001/result.txt
    before=$(sha256sum .git/index | awk '{print $1}')
    git status --short > work/001/status.txt
    if git add work/001/result.txt 2>/dev/null; then printf writable > work/001/git.txt; else printf blocked > work/001/git.txt; fi
    after=$(sha256sum .git/index | awk '{print $1}')
    [ "$before" = "$after" ]
    [ ! -e .git/index.lock ]
    ;;
  scratch)
    cp analytics/sample.py "$TMPDIR/sample.py"
    printf '\n# changed\n' >> "$TMPDIR/sample.py"
    ! cmp -s analytics/sample.py "$TMPDIR/sample.py"
    mkdir -p work/001; printf scratch > work/001/result.txt
    ;;
  hang)
    mkdir -p work/001
    printf '%s\n' "$$" > work/001/worker.pid
    exec -a pipeline-claude-isolation-test sleep 30
    ;;
  *) exit 9 ;;
esac
STUB
  chmod +x "$FIX/bin/claude"
}

install_codex_stub() {
  cat > "$FIX/bin/codex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = login ] && [ "${2:-}" = status ]; then
  [ "${STUB_CODEX_LOGGED_IN:-1}" = 1 ]
  exit
fi
printf 'CODEX ' >> "$STUB_TRACE"
printf '%q ' "$@" >> "$STUB_TRACE"
printf '\n' >> "$STUB_TRACE"
wt=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[$i]}" = -C ]; then wt="${args[$((i+1))]}"; fi
done
[ -n "$wt" ] || exit 8
case "${STUB_BEHAVIOR:-success}" in
  success) mkdir -p "$wt/work/001"; printf 'codex\n' > "$wt/work/001/result.txt" ;;
  *) exit 9 ;;
esac
STUB
  chmod +x "$FIX/bin/codex"
}

install_bwrap_stub() {
  cat > "$FIX/bin/bwrap" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --version ]; then printf 'bubblewrap test 1.0\n'; exit 0; fi
cwd=""
declare -a env_pairs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --die-with-parent|--new-session|--unshare-all|--share-net) shift ;;
    --ro-bind|--bind) shift 3 ;;
    --proc|--dev) shift 2 ;;
    --setenv) env_pairs+=("$2=$3"); shift 3 ;;
    --chdir) cwd="$2"; shift 2 ;;
    --) shift; break ;;
    *) printf 'unexpected fake bwrap option: %s\n' "$1" >&2; exit 97 ;;
  esac
done
if [ "${1:-}" = /bin/sh ]; then
  argc=$#
  eval "writable=\${$((argc-1))}"
  touch "$writable/writable"
  exit 0
fi
for pair in "${env_pairs[@]}"; do export "$pair"; done
[ -z "$cwd" ] || cd "$cwd"
exec "$@"
STUB
  chmod +x "$FIX/bin/bwrap"
}

run_poller() {
  env \
    PATH="$FIX/bin:$PATH" \
    STUB_TRACE="$TRACE" \
    STUB_BEHAVIOR="${STUB_BEHAVIOR:-success}" \
    STUB_CODEX_LOGGED_IN="${STUB_CODEX_LOGGED_IN:-1}" \
    PIPELINE_BUS="$FIX/bus" \
    PIPELINE_RUN_ROOT="$FIX/runs" \
    PIPELINE_CLAUDE_RUN_ROOT="${PIPELINE_CLAUDE_RUN_ROOT:-$FIX/claude-runs}" \
    PIPELINE_CLAUDE_BWRAP_BIN="${PIPELINE_CLAUDE_BWRAP_BIN:-$FIX/bin/bwrap}" \
    PIPELINE_CLAUDE_BIN="${PIPELINE_CLAUDE_BIN:-$FIX/bin/claude}" \
    PIPELINE_CLAUDE_TIMEOUT_SECONDS="${PIPELINE_CLAUDE_TIMEOUT_SECONDS:-0}" \
    PIPELINE_LOG="$LOG" \
    PIPELINE_LOCK="$LOCK" \
    PIPELINE_LOCAL_WORKERS="${PIPELINE_LOCAL_WORKERS:-claude}" \
    PIPELINE_CODEX_BIN="${PIPELINE_CODEX_BIN:-codex}" \
    PIPELINE_CODEX_MODEL="${PIPELINE_CODEX_MODEL:-}" \
    PIPELINE_CODEX_SANDBOX="${PIPELINE_CODEX_SANDBOX:-workspace-write}" \
    PIPELINE_CODEX_REASONING_EFFORT="${PIPELINE_CODEX_REASONING_EFFORT:-high}" \
    bash "$POLLER"
}

# 1. Existing default remains Claude, now through the isolation builder.
new_fixture claude_default
install_claude_stub
install_bwrap_stub
run_poller
[ "$(state_of "$FIX")" = review ] || fail claude_default "state is not review"
git --git-dir="$FIX/remote.git" show task/001:work/001/result.txt | grep -qx ok || fail claude_default "result missing"
grep -q '^CLAUDE ' "$TRACE" || fail claude_default "Claude was not invoked"
[ -z "$(find "$FIX/claude-runs" -mindepth 1 -print -quit)" ] || fail claude_default "isolation run directory leaked"
pass claude_default

# 2. Codex receives the existing non-interactive flags.
new_fixture codex_flags codex
install_codex_stub
PIPELINE_LOCAL_WORKERS=codex PIPELINE_CODEX_MODEL=test-codex run_poller
[ "$(state_of "$FIX")" = review ] || fail codex_flags "state is not review"
for needle in '-a' 'never' '--sandbox' 'workspace-write' '-m' 'test-codex' 'model_reasoning_effort=high' 'exec' '--ephemeral' '--json' '--output-last-message'; do
  grep -q -- "$needle" "$TRACE" || fail codex_flags "missing flag $needle"
done
pass codex_flags

# 3. Invalid Claude-only configuration does not gate a Codex task.
new_fixture codex_independent codex
install_codex_stub
PIPELINE_LOCAL_WORKERS=codex PIPELINE_CLAUDE_RUN_ROOT="$FIX/bus/inside" run_poller
[ "$(state_of "$FIX")" = review ] || fail codex_independent "Claude config blocked Codex"
pass codex_independent

# 4. Manual lane is never auto-claimed.
new_fixture manual_lane manual
PIPELINE_LOCAL_WORKERS=manual run_poller
[ "$(state_of "$FIX")" = queued ] || fail manual_lane "manual lane changed state"
pass manual_lane

# 5. Missing bubblewrap fails before claim and before Claude starts.
new_fixture missing_bwrap
install_claude_stub
PIPELINE_CLAUDE_BWRAP_BIN=missing-bwrap run_poller
[ "$(state_of "$FIX")" = queued ] || fail missing_bwrap "state changed before isolation preflight"
[ ! -e "$TRACE" ] || fail missing_bwrap "Claude ran without isolation"
pass missing_bwrap

# 6. Invalid Claude run root fails before claim.
new_fixture invalid_claude_root
install_claude_stub
install_bwrap_stub
PIPELINE_CLAUDE_RUN_ROOT="$FIX/bus/inside" run_poller
[ "$(state_of "$FIX")" = queued ] || fail invalid_claude_root "state changed for invalid run root"
[ ! -e "$TRACE" ] || fail invalid_claude_root "Claude ran with invalid root"
pass invalid_claude_root

# 7. A pre-existing symlink cannot turn the exact task bind into an external write.
new_fixture symlink_task_path
install_claude_stub
install_bwrap_stub
outside="$FIX/outside"
mkdir -p "$outside"
(
  cd "$FIX/seed"
  mkdir -p work
  ln -s "$outside" work/001
  git add work/001
  git commit -qm 'add hostile task symlink'
  git push -q origin main
)
git -C "$FIX/bus" pull -q --ff-only
run_poller
[ "$(state_of "$FIX")" = stuck ] || fail symlink_task_path "symlink task path was not rejected"
[ ! -e "$outside/result.txt" ] || fail symlink_task_path "worker wrote through task symlink"
[ ! -e "$TRACE" ] || fail symlink_task_path "Claude ran for a symlink task path"
pass symlink_task_path

# 8. Out-of-scope output remains quarantined by post-run validation.
new_fixture out_of_scope
install_claude_stub
install_bwrap_stub
STUB_BEHAVIOR=outscope run_poller
[ "$(state_of "$FIX")" = stuck ] || fail out_of_scope "unsafe output did not become stuck"
grep -q 'out-of-scope:README.md' "$LOG" || fail out_of_scope "reason not logged"
pass out_of_scope

# 9. Runner failure restores the exact pre-claim state and cleans isolation state.
new_fixture runner_failure
install_claude_stub
install_bwrap_stub
STUB_BEHAVIOR=fail run_poller
[ "$(state_of "$FIX")" = queued ] || fail runner_failure "failed runner did not roll back"
[ -z "$(find "$FIX/claude-runs" -mindepth 1 -print -quit)" ] || fail runner_failure "isolation run directory leaked"
pass runner_failure

# 10. Worker-created commits are rejected.
new_fixture head_move
install_claude_stub
install_bwrap_stub
STUB_BEHAVIOR=gitmove run_poller
[ "$(state_of "$FIX")" = stuck ] || fail head_move "HEAD movement did not become stuck"
pass head_move

# 11. Repository bytecode is rejected rather than ignored.
new_fixture bytecode_reject
install_claude_stub
install_bwrap_stub
STUB_BEHAVIOR=bytecode run_poller
[ "$(state_of "$FIX")" = stuck ] || fail bytecode_reject "repository cache was submitted"
grep -q 'python-cache:' "$LOG" || fail bytecode_reject "cache rejection not logged"
pass bytecode_reject

# 12. Explicit py_compile uses the external PYTHONPYCACHEPREFIX.
new_fixture pycompile_external
install_claude_stub
install_bwrap_stub
STUB_BEHAVIOR=pycompile run_poller
[ "$(state_of "$FIX")" = review ] || fail pycompile_external "py_compile task did not submit"
git --git-dir="$FIX/remote.git" show task/001:work/001/result.txt | grep -qx pycache-external || fail pycompile_external "pycache proof missing"
pass pycompile_external

# 13. Writable scratch is external to the worker clone.
new_fixture scratch_external
install_claude_stub
install_bwrap_stub
STUB_BEHAVIOR=scratch run_poller
[ "$(state_of "$FIX")" = review ] || fail scratch_external "scratch task did not submit"
pass scratch_external

# 14. A real TERM reaches the managed child and cleans the per-run directory.
new_fixture signal_cleanup
install_claude_stub
install_bwrap_stub
(
  exec env \
    PATH="$FIX/bin:$PATH" \
    STUB_TRACE="$TRACE" \
    STUB_BEHAVIOR=hang \
    STUB_CODEX_LOGGED_IN=1 \
    PIPELINE_BUS="$FIX/bus" \
    PIPELINE_RUN_ROOT="$FIX/runs" \
    PIPELINE_CLAUDE_RUN_ROOT="$FIX/claude-runs" \
    PIPELINE_CLAUDE_BWRAP_BIN="$FIX/bin/bwrap" \
    PIPELINE_CLAUDE_BIN="$FIX/bin/claude" \
    PIPELINE_CLAUDE_TIMEOUT_SECONDS=0 \
    PIPELINE_LOG="$LOG" \
    PIPELINE_LOCK="$LOCK" \
    PIPELINE_LOCAL_WORKERS=claude \
    PIPELINE_CODEX_BIN=codex \
    PIPELINE_CODEX_SANDBOX=workspace-write \
    PIPELINE_CODEX_REASONING_EFFORT=high \
    bash "$POLLER"
) &
poller_pid=$!
pid_file=""
for _ in $(seq 1 600); do
  pid_file=$(find "$FIX/runs" -path '*/worker/work/001/worker.pid' -print -quit 2>/dev/null || true)
  [ -n "$pid_file" ] && break
  kill -0 "$poller_pid" 2>/dev/null || break
  sleep 0.05
done
if [ -z "$pid_file" ]; then
  kill -TERM "$poller_pid" 2>/dev/null || true
  wait "$poller_pid" 2>/dev/null || true
  fail signal_cleanup "worker did not start"
fi
worker_pid=$(cat "$pid_file")
kill -TERM "$poller_pid"
for _ in $(seq 1 200); do
  kill -0 "$poller_pid" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "$poller_pid" 2>/dev/null; then
  kill -KILL "$poller_pid" 2>/dev/null || true
  fail signal_cleanup "poller did not finish after TERM"
fi
wait "$poller_pid" || true
kill -0 "$worker_pid" 2>/dev/null && fail signal_cleanup "worker child survived TERM"
[ -z "$(find "$FIX/claude-runs" -mindepth 1 -print -quit)" ] || fail signal_cleanup "isolation run directory leaked"
[ "$(state_of "$FIX")" = queued ] || fail signal_cleanup "interrupted task did not roll back"
pass signal_cleanup

# 15. One flock permits only one claimant.
new_fixture flock
install_claude_stub
install_bwrap_stub
(
  STUB_BEHAVIOR=slow run_poller
) &
first=$!
sleep 0.3
STUB_BEHAVIOR=slow run_poller
wait "$first"
[ "$(grep -c '^CLAUDE ' "$TRACE")" -eq 1 ] || fail flock "runner invoked more than once"
[ "$(state_of "$FIX")" = review ] || fail flock "final state is not review"
pass flock

# 16. Real bubblewrap boundary checks run when the host supports them.
if command -v bwrap >/dev/null 2>&1 && bwrap --die-with-parent --unshare-all --share-net --ro-bind / / --proc /proc --dev /dev -- /bin/true >/dev/null 2>&1; then
  new_fixture real_boundary
  install_claude_stub
  STUB_BEHAVIOR=boundary PIPELINE_CLAUDE_BWRAP_BIN="$(command -v bwrap)" run_poller
  [ "$(state_of "$FIX")" = review ] || fail real_boundary "real boundary task did not submit"
  git --git-dir="$FIX/remote.git" show task/001:work/001/result.txt | grep -qx 'blocked blocked' || fail real_boundary "root or sibling task was writable"
  pass real_boundary

  new_fixture real_git_boundary
  install_claude_stub
  STUB_BEHAVIOR=gitboundary PIPELINE_CLAUDE_BWRAP_BIN="$(command -v bwrap)" run_poller
  [ "$(state_of "$FIX")" = review ] || fail real_git_boundary "git boundary task did not submit"
  git --git-dir="$FIX/remote.git" show task/001:work/001/git.txt | grep -qx blocked || fail real_git_boundary "Git index was writable"
  pass real_git_boundary
else
  echo 'SKIP real bubblewrap boundary (unavailable or unusable)'
fi

bash -n "$POLLER"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$POLLER"
  echo 'PASS shellcheck'
else
  echo 'SKIP shellcheck (not installed)'
fi
