#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
POLLER="$ROOT/wsl/poller.sh"
TMP_ROOT=$(mktemp -d -t pipeline-codex-test-XXXXXX)
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
    mkdir -p tasks status work reviews wsl
    printf '# protocol\n' > PROTOCOL.md
    printf '# task\n\nmode: patch\n' > tasks/001-test.md
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
  mkdir -p "$FIX/bin" "$FIX/runs"
  chmod 700 "$FIX/runs"
  TRACE="$FIX/trace"
  LOG="$FIX/poller.log"
  LOCK="$FIX/poller.lock"
}

install_claude_stub() {
  cat > "$FIX/bin/claude" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'CLAUDE %q ' "$@" >> "$STUB_TRACE"; printf '\n' >> "$STUB_TRACE"
case "${STUB_BEHAVIOR:-success}" in
  success) mkdir -p work/001; printf 'ok\n' > work/001/result.txt ;;
  outscope) printf 'bad\n' > README.md ;;
  fail) mkdir -p work/001; printf 'partial\n' > work/001/result.txt; exit 7 ;;
  slow) sleep 2; mkdir -p work/001; printf 'ok\n' > work/001/result.txt ;;
  gitmove) git config user.name bad; git config user.email bad@example.invalid; mkdir -p work/001; echo bad > work/001/result.txt; git add .; git commit -qm bad ;;
  *) exit 9 ;;
esac
STUB
  chmod +x "$FIX/bin/claude"
}

install_codex_stub() {
  cat > "$FIX/bin/codex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then
  [ "${STUB_CODEX_LOGGED_IN:-1}" = "1" ]
  exit
fi
printf 'CODEX ' >> "$STUB_TRACE"
printf '%q ' "$@" >> "$STUB_TRACE"
printf '\n' >> "$STUB_TRACE"
wt=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[$i]}" = "-C" ]; then wt="${args[$((i+1))]}"; fi
done
[ -n "$wt" ] || exit 8
case "${STUB_BEHAVIOR:-success}" in
  success) mkdir -p "$wt/work/001"; printf 'codex\n' > "$wt/work/001/result.txt" ;;
  outscope) printf 'bad\n' > "$wt/README.md" ;;
  fail) mkdir -p "$wt/work/001"; printf 'partial\n' > "$wt/work/001/result.txt"; exit 7 ;;
  slow) sleep 2; mkdir -p "$wt/work/001"; printf 'codex\n' > "$wt/work/001/result.txt" ;;
  gitmove) (cd "$wt" && git config user.name bad && git config user.email bad@example.invalid && mkdir -p work/001 && echo bad > work/001/result.txt && git add . && git commit -qm bad) ;;
  *) exit 9 ;;
esac
STUB
  chmod +x "$FIX/bin/codex"
}

run_poller() {
  env \
    PATH="$FIX/bin:$PATH" \
    STUB_TRACE="$TRACE" \
    STUB_BEHAVIOR="${STUB_BEHAVIOR:-success}" \
    STUB_CODEX_LOGGED_IN="${STUB_CODEX_LOGGED_IN:-1}" \
    PIPELINE_BUS="$FIX/bus" \
    PIPELINE_RUN_ROOT="$FIX/runs" \
    PIPELINE_LOG="$LOG" \
    PIPELINE_LOCK="$LOCK" \
    PIPELINE_LOCAL_WORKERS="${PIPELINE_LOCAL_WORKERS:-claude}" \
    PIPELINE_CODEX_BIN="${PIPELINE_CODEX_BIN:-codex}" \
    PIPELINE_CODEX_MODEL="${PIPELINE_CODEX_MODEL:-}" \
    PIPELINE_CODEX_SANDBOX="${PIPELINE_CODEX_SANDBOX:-workspace-write}" \
    PIPELINE_CODEX_REASONING_EFFORT="${PIPELINE_CODEX_REASONING_EFFORT:-high}" \
    bash "$POLLER"
}

# 1. Existing default remains Claude.
new_fixture claude_default
install_claude_stub
run_poller
[ "$(state_of "$FIX")" = review ] || fail claude_default "state is not review"
git --git-dir="$FIX/remote.git" show task/001:work/001/result.txt | grep -qx ok || fail claude_default "result missing"
grep -q '^CLAUDE ' "$TRACE" || fail claude_default "Claude was not invoked"
pass claude_default

# 2. Codex receives non-interactive, sandbox, JSON and reasoning flags.
new_fixture codex_flags codex
install_codex_stub
PIPELINE_LOCAL_WORKERS=codex PIPELINE_CODEX_MODEL=test-codex run_poller
[ "$(state_of "$FIX")" = review ] || fail codex_flags "state is not review"
grep -q '^CODEX ' "$TRACE" || fail codex_flags "Codex was not invoked"
for needle in '-a' 'never' '--sandbox' 'workspace-write' '-m' 'test-codex' 'model_reasoning_effort=high' 'exec' '--ephemeral' '--json' '--output-last-message'; do
  grep -q -- "$needle" "$TRACE" || fail codex_flags "missing flag $needle"
done
pass codex_flags

# 3. Manual lane is never auto-claimed.
new_fixture manual_lane manual
PIPELINE_LOCAL_WORKERS=manual run_poller
[ "$(state_of "$FIX")" = queued ] || fail manual_lane "manual lane changed state"
[ ! -e "$TRACE" ] || fail manual_lane "a runner was invoked"
pass manual_lane

# 4. Missing Codex binary fails before claim.
new_fixture missing_codex codex
PIPELINE_LOCAL_WORKERS=codex PIPELINE_CODEX_BIN=missing-codex run_poller
[ "$(state_of "$FIX")" = queued ] || fail missing_codex "state changed before preflight"
pass missing_codex

# 5. Logged-out Codex fails before claim.
new_fixture logged_out codex
install_codex_stub
STUB_CODEX_LOGGED_IN=0 PIPELINE_LOCAL_WORKERS=codex run_poller
[ "$(state_of "$FIX")" = queued ] || fail logged_out "state changed before auth preflight"
[ ! -e "$TRACE" ] || fail logged_out "Codex exec ran while logged out"
pass logged_out

# 6. Unsafe sandbox is rejected before spawn.
new_fixture sandbox_reject codex
install_codex_stub
PIPELINE_LOCAL_WORKERS=codex PIPELINE_CODEX_SANDBOX=danger-full-access run_poller
[ "$(state_of "$FIX")" = queued ] || fail sandbox_reject "state changed for unsafe sandbox"
[ ! -e "$TRACE" ] || fail sandbox_reject "Codex ran with unsafe sandbox"
pass sandbox_reject

# 7. Out-of-scope output is quarantined as stuck.
new_fixture out_of_scope
install_claude_stub
STUB_BEHAVIOR=outscope run_poller
[ "$(state_of "$FIX")" = stuck ] || fail out_of_scope "unsafe output did not become stuck"
grep -q 'out-of-scope:README.md' "$LOG" || fail out_of_scope "reason not logged"
pass out_of_scope

# 8. Runner failure restores the exact pre-claim state.
new_fixture runner_failure
install_claude_stub
STUB_BEHAVIOR=fail run_poller
[ "$(state_of "$FIX")" = queued ] || fail runner_failure "failed runner did not roll back"
pass runner_failure

# 9. Worker-created commits are rejected without using worker Git metadata.
new_fixture head_move
install_claude_stub
STUB_BEHAVIOR=gitmove run_poller
[ "$(state_of "$FIX")" = stuck ] || fail head_move "HEAD movement did not become stuck"
pass head_move

# 10. One flock permits only one claimant.
new_fixture flock
install_claude_stub
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

bash -n "$POLLER"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$POLLER"
  echo 'PASS shellcheck'
else
  echo 'SKIP shellcheck (not installed)'
fi
