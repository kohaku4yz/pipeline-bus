# Pipeline-launched Claude filesystem isolation

This document describes the write boundary used only by the automated `worker=claude` lane. It does not wrap interactive Claude sessions and does not change the Codex runner.

## Security goal

The worker receives a disposable clone so it can read the task, protocol, prior reviews, and source files. Before Claude starts, the poller must prove that bubblewrap is usable on the current host. The run is then launched with:

- the host root mounted read-only;
- the complete disposable worker clone mounted read-only, including `.git/`;
- only the exact current task directory, `work/<task>/`, bind-mounted read-write;
- a unique repository-external run directory with separate writable `scratch`, `tmp`, `pycache`, and `runtime` subdirectories;
- `TMPDIR`, `PYTHONPYCACHEPREFIX`, `XDG_CACHE_HOME`, and `XDG_STATE_HOME` redirected into that run directory;
- inherited Git redirection variables removed;
- network access retained for the CLI;
- existing host authentication left in place but read-only from the sandbox.

There is no unisolated fallback. If the executable, namespace operation, read-only-root probe, writable-bind probe, timeout configuration, or private run root is invalid, the task remains unclaimed.

## Writable-path map

| Path | Access inside automated Claude run | Purpose |
|---|---:|---|
| disposable clone root | read-only | Task and source inspection |
| disposable clone `.git/` | read-only | Read-only Git inspection without index/ref mutation |
| `work/<task>/` | read-write | The only repository output allowlist |
| per-run `scratch/` | read-write | Mutable copies for experiments |
| per-run `tmp/` | read-write | Temporary files (`TMPDIR`) |
| per-run `pycache/` | read-write | Python bytecode (`PYTHONPYCACHEPREFIX`) |
| per-run `runtime/` | read-write | XDG cache/state required by the headless CLI |
| all other host paths | read-only | Runtime binaries, libraries, and existing authentication |

The wrapper still snapshots the disposable clone before and after execution. A second, fresh submission clone receives only validated ordinary files under `work/<task>/`. The existing checks for moved HEAD, out-of-scope paths, symlinks, unsupported file types, secret-shaped names, and empty output remain active.

Repository-local Python caches are explicitly rejected even when they are under the task allowlist. Any path containing a case-insensitive `__pycache__` component or ending in `.pyc` fails validation and is not copied or staged.

## Process lifecycle

The poller owns the bubblewrap child PID. For `INT`, `TERM`, or `HUP`, it terminates the managed child, escalates to `KILL` when necessary, reaps it, and removes only the unique per-run directory. An optional `PIPELINE_CLAUDE_TIMEOUT_SECONDS` uses the same managed-child path. Success, worker failure, timeout, and handled interruption all clean the isolation directory before the task is submitted or rolled back.

`PIPELINE_CLAUDE_TIMEOUT_SECONDS=0` means no additional wrapper timeout. A non-negative integer enables one.

## Threat model and limits

This boundary is designed to prevent a pipeline-launched Claude process from writing to the control plane, Git metadata, sibling task directories, source files, or persistent global CLI state. It is stronger than prompt instructions, command-name filtering, environment hints, or same-UID file permissions.

It is intentionally a **filesystem write boundary**, not a confidentiality boundary:

- the host root is read-only visible so installed binaries, libraries, and existing Claude authentication continue to work;
- network access is shared intentionally;
- the task dispatcher must therefore remain trusted;
- this does not replace a dedicated VM/container boundary for hostile multi-tenant execution.

The Codex lane retains its existing CLI sandbox and run-log behavior. Claude-only configuration is resolved lazily, after assignment, so broken Claude isolation settings cannot block a Codex task.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `PIPELINE_CLAUDE_BIN` | `claude` | Claude CLI used only by the automated lane |
| `PIPELINE_MODEL` | empty | Optional Claude model override |
| `PIPELINE_CLAUDE_BWRAP_BIN` | `bwrap` | bubblewrap executable |
| `PIPELINE_CLAUDE_RUN_ROOT` | `$HOME/.local/state/pipeline-bus/claude-runs` | Private external per-run root; absolute, outside the bus, owned by the current user, mode `0700` |
| `PIPELINE_CLAUDE_TIMEOUT_SECONDS` | `0` | Optional non-negative timeout; `0` disables it |

## Regression coverage

The hermetic worker suite verifies:

1. the default Claude lane still reaches `review` through the production isolation builder;
2. Codex flags and task submission remain unchanged;
3. invalid Claude-only configuration does not gate Codex;
4. missing/unusable bubblewrap and invalid run roots fail before claim;
5. post-run validation still quarantines out-of-scope output and worker-created commits;
6. repository `.pyc` and `__pycache__` paths are rejected;
7. explicit `python3 -m py_compile` places bytecode only under external `PYTHONPYCACHEPREFIX`;
8. external scratch can be modified without changing source files;
9. worker failure rolls back state and cleans the run directory;
10. a real `TERM` reaches the managed child, reaps it, cleans the run directory, and rolls back the task;
11. `flock` still permits only one claimant;
12. when the host supports bubblewrap, real mount-boundary cases prove that source/sibling writes and Git index writes fail while task output and read-only Git inspection work.

The real mount-boundary cases skip explicitly on hosts where bubblewrap is unavailable or user namespaces are disabled; deployment must pass the same production preflight before a Claude task can be claimed.
