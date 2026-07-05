#!/usr/bin/env python3
"""
pipeline-bus analytics — zero-intrusion stats lens.

Reads `git log` from the pipeline-bus checkout (read-only) and rebuilds a
stage-by-stage report of every task that has passed through the pipeline:
queue → claim → submit review → verdict → merged. No protocol / poller /
reviewer code is touched; everything is recovered from commit timestamps +
message patterns.

Optional `--tokens` flag joins session jsonl from `~/.claude/projects/...` to
attribute per-task input/output/cache tokens. When the jsonl is missing or
malformed, the flag degrades gracefully to N/A — never crashes the report.

Usage (run from the repo checkout root):
    python3 analytics/stats.py           # terminal table
    python3 analytics/stats.py --json    # machine format
    python3 analytics/stats.py --md      # markdown table for README
    python3 analytics/stats.py --tokens  # include per-task token usage

Display timezone defaults to system local. Override with the `PIPELINE_TZ`
environment variable (UTC offset in hours, e.g. `export PIPELINE_TZ=9` for
UTC+9) or the `--tz <hours>` CLI flag.

The script intentionally uses only the Python standard library.
"""

from __future__ import annotations

import argparse
import ast
import glob
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Iterable

# --- timezone handling -------------------------------------------------------

from datetime import timedelta


def _display_tz() -> timezone:
    """Pick the timezone used for display. Resolution order:
    1. `--tz` CLI flag (stored on `args.tz` by `main`, see below).
    2. `PIPELINE_TZ` env var as a UTC offset in hours, e.g. `9` or `-5`.
    3. System local time (`datetime.now().astimezone().tzinfo`).
    4. UTC as a final fallback for environments that report a None tzinfo.
    """
    cli_tz = getattr(_display_tz, "override", None)
    if cli_tz is not None:
        return cli_tz
    env_tz = os.environ.get("PIPELINE_TZ")
    if env_tz:
        try:
            return timezone(timedelta(hours=float(env_tz)))
        except ValueError:
            pass
    local = datetime.now().astimezone().tzinfo
    return local or timezone.utc


def to_display(ts: datetime) -> datetime:
    """Coerce a naive/aware datetime into the display timezone. Naive
    timestamps are interpreted as UTC; `git log --pretty=%aI` usually hands
    us ISO-8601 with an offset, so the common case is already aware."""
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    return ts.astimezone(_display_tz())


def parse_git_ts(raw: str) -> datetime:
    """`git log --pretty=%aI` yields RFC-3339 with offset, e.g.
    `2026-07-04T14:50:03+09:00`. `datetime.fromisoformat` handles this since
    Python 3.11 (and tolerates it from 3.7 onward for the common shapes)."""
    return datetime.fromisoformat(raw)


# --- duration formatting -----------------------------------------------------


def fmt_duration(seconds: float | None) -> str:
    """Render a duration as `4h32m` / `12m05s` / `38s`. None → `N/A`.
    Negative durations (clock weirdness) get a leading `*` footnote marker."""
    if seconds is None:
        return "N/A"
    if seconds < 0:
        # flag as anomalous; render the magnitude as if positive
        return "*" + _fmt_pos(abs(seconds))
    return _fmt_pos(seconds)


def _fmt_pos(seconds: float) -> str:
    s = int(round(seconds))
    if s < 60:
        return f"{s}s"
    m, s = divmod(s, 60)
    if m < 60:
        return f"{m}m{s:02d}s"
    h, m = divmod(m, 60)
    if h < 24:
        return f"{h}h{m:02d}m"
    d, h = divmod(h, 24)
    return f"{d}d{h:02d}h"


def seconds_between(a: datetime, b: datetime) -> float:
    return (b - a).total_seconds()


# --- event parsing -----------------------------------------------------------

# Commit message patterns matched by this analytics layer.
#
# The shipped poller (`wsl/poller.sh`) and reviewer (`vps/reviewer_poll.sh`)
# emit exactly these substrings in their commits, so the regexes below are
# load-bearing — they are part of the protocol contract. If the poller or
# reviewer is edited (e.g. `task NNN → review` is reworded), the matching
# regex must be edited in lockstep or the report will silently drop stage
# events.
#
#   claim task NNN (doing)                            (poller.claim)
#   task NNN: implementation (round N)                (poller.submit)
#   task NNN → review                                 (poller.submit → review)
#   task NNN: review rN → approved | changes_requested | stuck   (reviewer)
#   task NNN → merged                                 (Owner closes task)
#
# Soft patterns (dormant unless a human or a custom dispatcher uses them):
#   queue task NNN — <title>                          (Owner-side queue marker)
#   task NNN: unstuck for round N                     (manual recovery)
#
# The `queue task NNN` pattern requires the Owner-side dispatcher to commit
# with the literal word `queue`. The shipped dispatcher only writes the
# status file, not a queue commit; without a custom commit message, the
# `queue→claim` column renders as `N/A` for every task. This is a graceful
# degradation — every other stage still reports correctly.

RE_QUEUE = re.compile(r"\bqueue\s+task\s+(\d{3})\b")
# Combined-queue form: a single commit that dispatches multiple tasks,
# e.g. `queue task 002 (title one) + 003 (title two)`. After the first NNN,
# additional 3-digit numbers introduced by `+` are harvested from the same
# dispatch window. This pattern is dormant in the shipped dispatcher; it is
# retained so a custom dispatcher that batches tasks still parses.
RE_QUEUE_EXTRA = re.compile(r"\+\s*(\d{3})\b")
RE_CLAIM = re.compile(r"\bclaim\s+task\s+(\d{3})\s*\(doing\)")
RE_SUBMIT = re.compile(r"\btask\s+(\d{3})\s*→\s*review\b")
RE_VERDICT = re.compile(
    r"\btask\s+(\d{3})\s*:\s*review\s*r(\d+)\s*→\s*(approved|changes_requested|stuck)\b"
)
RE_MERGED = re.compile(r"\btask\s+(\d{3})\s*→\s*merged\b")
RE_UNSTUCK = re.compile(r"\btask\s+(\d{3})\s*:\s*unstuck\b")
RE_IMPL = re.compile(
    r"\btask\s+(\d{3})\s*(?:round\s*(\d+)\s*:|:?\s*implementation\s*\(round\s*(\d+)\))"
)
RE_REVIEW_HUMAN = re.compile(
    r"\breview\s+task\s+(\d{3})\s+round\s+(\d+)\s*:\s*(APPROVED|NEEDS_CHANGES|STUCK)\b"
)
RE_LIVE_FIRE = re.compile(
    r"\btask\s+(\d{3})\s*:\s*live-fire\s+fixes\b"
)


@dataclass
class Event:
    ts: datetime
    kind: str          # queue | claim | submit | verdict | merged | unstuck | impl | review_human | live_fire
    task: str
    detail: str = ""   # e.g. "approved" or round number


def parse_message(msg: str, ts: datetime) -> list[Event]:
    """A single commit may carry multiple events (e.g. `queue task 002 + 003`).
    We yield one Event per match; ambiguous matches (e.g. human-written
    `task NNN: implementation (round N)`) add an impl event but never a
    structural stage event — those come from the arrow-syntax commits."""
    out: list[Event] = []
    for m in RE_QUEUE.finditer(msg):
        out.append(Event(ts, "queue", m.group(1)))
    # Only harvest extras if a primary `queue task NNN` was matched AND the
    # extras appear in the same dispatch window (within 60 chars of the
    # primary match) — this keeps us from confusing `+ 003` for, say, a
    # cross-reference inside a release note.
    if RE_QUEUE.search(msg):
        primary_end = RE_QUEUE.search(msg).end()
        for m in RE_QUEUE_EXTRA.finditer(msg, primary_end, primary_end + 60):
            out.append(Event(ts, "queue", m.group(1)))
    for m in RE_CLAIM.finditer(msg):
        out.append(Event(ts, "claim", m.group(1)))
    for m in RE_SUBMIT.finditer(msg):
        out.append(Event(ts, "submit", m.group(1)))
    for m in RE_VERDICT.finditer(msg):
        out.append(Event(ts, "verdict", m.group(1), f"r{m.group(2)}:{m.group(3)}"))
    for m in RE_MERGED.finditer(msg):
        out.append(Event(ts, "merged", m.group(1)))
    for m in RE_UNSTUCK.finditer(msg):
        out.append(Event(ts, "unstuck", m.group(1)))
    for m in RE_IMPL.finditer(msg):
        round_no = m.group(2) or m.group(3) or "1"
        out.append(Event(ts, "impl", m.group(1), f"r{round_no}"))
    for m in RE_REVIEW_HUMAN.finditer(msg):
        kind = {"APPROVED": "approved", "NEEDS_CHANGES": "changes_requested",
                "STUCK": "stuck"}[m.group(3)]
        out.append(Event(ts, "verdict", m.group(1), f"r{m.group(2)}:{kind}"))
    for m in RE_LIVE_FIRE.finditer(msg):
        out.append(Event(ts, "live_fire", m.group(1)))
    return out


# --- git log ingestion -------------------------------------------------------


def git_log(repo_root: str) -> list[tuple[datetime, str, str]]:
    """Return [(timestamp, author, subject), ...] from every ref, oldest first.

    We pull from `--all` so task-branch-only commits (e.g. `implementation
    (round 2)`) are visible; main alone misses them. Each row is one commit."""
    pretty = "%aI%x1f%an%x1f%s"  # record-sep delimited; matches PROTOCOL.md fields
    proc = subprocess.run(
        ["git", "-C", repo_root, "log", "--all", f"--pretty={pretty}"],
        capture_output=True, text=True, check=True,
    )
    rows: list[tuple[datetime, str, str]] = []
    for line in proc.stdout.splitlines():
        if not line:
            continue
        parts = line.split("\x1f", 2)
        if len(parts) != 3:
            continue
        ts_raw, author, subject = parts
        try:
            ts = parse_git_ts(ts_raw)
        except ValueError:
            continue
        rows.append((ts, author, subject))
    rows.sort(key=lambda r: r[0])  # oldest first; defensive (git is already)
    return rows


# --- per-task timeline reconstruction ---------------------------------------


@dataclass
class Round:
    """A single review round: one claim → one submit → one verdict (when
    present). Multiple rounds are tracked independently for `review_rounds`."""
    claim: datetime | None = None
    submit: datetime | None = None
    verdict: datetime | None = None
    verdict_state: str | None = None  # approved | changes_requested | stuck


@dataclass
class TaskTimeline:
    task: str
    queue: datetime | None = None
    merged: datetime | None = None
    rounds: list[Round] = field(default_factory=list)
    unstuck_count: int = 0
    live_fire_count: int = 0
    anomaly_notes: list[str] = field(default_factory=list)


def build_timelines(events: Iterable[Event]) -> dict[str, TaskTimeline]:
    """Replay events in order and fold them into per-task timelines.

    Heuristics for round bookkeeping:
    - Every `claim` either opens a new round (if previous round has no verdict
      yet) or reopens the most recent round that ended in `changes_requested`.
      The latter is what `task NNN: unstuck for round N` describes.
    - `submit` always closes the current open round's implementation phase.
    - `verdict` closes the current open round's review phase and may prompt
      another `claim` (which opens a new round).
    """
    timelines: dict[str, TaskTimeline] = {}

    def get(t: str) -> TaskTimeline:
        if t not in timelines:
            timelines[t] = TaskTimeline(task=t)
        return timelines[t]

    # We need to replay events sorted by time. The caller already sorts.
    sorted_events = sorted(events, key=lambda e: e.ts)

    for ev in sorted_events:
        tl = get(ev.task)

        if ev.kind == "queue":
            # The first queue sets the start; subsequent queues (rare) are
            # treated as no-ops but noted.
            if tl.queue is None:
                tl.queue = ev.ts
            else:
                tl.anomaly_notes.append(f"duplicate queue at {ev.ts.isoformat()}")
        elif ev.kind == "claim":
            if not tl.rounds or (tl.rounds[-1].verdict is not None):
                tl.rounds.append(Round(claim=ev.ts))
            else:
                # Claim without an intervening verdict = restart (e.g. poller
                # re-claim race condition). Update the in-flight round's
                # claim time; flag as a rollback.
                tl.rounds[-1].claim = ev.ts
                tl.anomaly_notes.append(
                    f"re-claim at {ev.ts.isoformat()} without prior verdict "
                    f"(rollback)"
                )
        elif ev.kind == "submit":
            if not tl.rounds:
                tl.rounds.append(Round(claim=None, submit=ev.ts))
            else:
                tl.rounds[-1].submit = ev.ts
        elif ev.kind == "verdict":
            if not tl.rounds:
                tl.rounds.append(Round(submit=None, verdict=ev.ts))
                tl.rounds[-1].verdict = ev.ts
                tl.rounds[-1].verdict_state = ev.detail.split(":", 1)[1]
            else:
                tl.rounds[-1].verdict = ev.ts
                tl.rounds[-1].verdict_state = ev.detail.split(":", 1)[1]
        elif ev.kind == "merged":
            tl.merged = ev.ts
        elif ev.kind == "unstuck":
            tl.unstuck_count += 1
        elif ev.kind == "live_fire":
            tl.live_fire_count += 1
        # 'impl' events are descriptive — they confirm a round but add no
        # timing; we silently skip.

    return timelines


# --- metrics ----------------------------------------------------------------


def compute_metrics(tl: TaskTimeline, now: datetime) -> dict[str, Any]:
    """Reduce a TaskTimeline into the fields the report needs."""
    queue_to_claim: float | None = None
    if tl.queue and tl.rounds and tl.rounds[0].claim:
        queue_to_claim = seconds_between(tl.queue, tl.rounds[0].claim)

    # Implementation time = sum of (claim → submit) per round.
    impl_seconds: float = 0.0
    impl_parts: list[float] = []
    for r in tl.rounds:
        if r.claim and r.submit:
            d = seconds_between(r.claim, r.submit)
            impl_parts.append(d)
            impl_seconds += d

    # Review time = sum of (submit → verdict) per round.
    review_seconds: float = 0.0
    review_parts: list[float] = []
    review_states: list[str] = []
    for r in tl.rounds:
        if r.submit and r.verdict:
            d = seconds_between(r.submit, r.verdict)
            review_parts.append(d)
            review_seconds += d
            if r.verdict_state:
                review_states.append(r.verdict_state)

    rounds_completed = sum(1 for r in tl.rounds if r.verdict is not None)

    # Final-stage = LAST terminal verdict (approved or stuck) → merged.
    # The task spec calls this "人工终审时长（approved/stuck→merged）" — both
    # terminal verdicts count, because either one ends the review pipeline and
    # hands off to the Owner for the manual landing step. We do NOT take the last
    # `changes_requested` verdict, since that opens another round rather than
    # terminating the review.
    final_seconds: float | None = None
    last_terminal: datetime | None = None
    for r in tl.rounds:
        if r.verdict_state in ("approved", "stuck") and r.verdict:
            last_terminal = r.verdict
    if last_terminal and tl.merged:
        final_seconds = seconds_between(last_terminal, tl.merged)

    # End-to-end: queue → merged (or queue → now for in-flight tasks).
    if tl.queue and tl.merged:
        e2e = seconds_between(tl.queue, tl.merged)
        e2e_open = False
    elif tl.queue:
        e2e = seconds_between(tl.queue, now)
        e2e_open = True
    else:
        e2e = None
        e2e_open = False

    # Rollback count: extra `claim`s beyond the number of rounds. We compare
    # total claim events against unique rounds opened; the parser collapses
    # extra claims into `anomaly_notes`, but we keep a coarse count here.
    rollback_count = sum(
        1 for n in tl.anomaly_notes if "re-claim" in n
    )

    stuck_occurred = "stuck" in review_states

    # Final state for the report: merged | approved | stuck | changes_requested
    # | doing | queued. We infer from terminal events. `last_terminal` covers
    # approved and stuck alike (see the final_seconds block above for why).
    last_terminal_state: str | None = None
    for r in tl.rounds:
        if r.verdict_state in ("approved", "stuck") and r.verdict:
            last_terminal_state = r.verdict_state

    if tl.merged:
        final_state = "merged"
    elif last_terminal_state:
        final_state = last_terminal_state
    elif tl.rounds and tl.rounds[-1].verdict_state:
        final_state = tl.rounds[-1].verdict_state
    elif tl.rounds:
        final_state = "doing"
    elif tl.queue:
        final_state = "queued"
    else:
        final_state = "unknown"

    return {
        "queue_at": tl.queue,
        "merged_at": tl.merged,
        "queue_to_claim": queue_to_claim,
        "impl_seconds": impl_seconds,
        "impl_parts": impl_parts,
        "review_seconds": review_seconds,
        "review_parts": review_parts,
        "review_rounds": rounds_completed,
        "final_seconds": final_seconds,
        "end_to_end": e2e,
        "end_to_end_open": e2e_open,
        "rollback_count": rollback_count,
        "unstuck_count": tl.unstuck_count,
        "live_fire_count": tl.live_fire_count,
        "stuck_occurred": stuck_occurred,
        "anomaly_notes": tl.anomaly_notes,
        "final_state": final_state,
    }


# --- jsonl token attribution (v2) -------------------------------------------


def collect_task_tokens(repo_root: str) -> dict[str, dict[str, int]]:
    """For each session jsonl under `~/.claude/projects/<repo-key>/`, parse the
    `lastPrompt` for a `tasks/NNN-*.md` reference and sum `usage.input_tokens`
    / `output_tokens` / `cache_read_input_tokens` / `cache_creation_input_tokens`
    across every assistant turn in that session.

    Returns: {task_id: {in, out, cache_read, cache_create, sessions}, ...}

    Sessions whose lastPrompt does not mention any `tasks/NNN-*` are skipped
    (e.g. interactive debugging sessions).

    Robust to:
    - missing directory (returns {})
    - non-conforming `message` strings (skipped, not fatal)
    - missing `usage` field (turn skipped, others counted)
    """
    home = os.path.expanduser("~")
    # The directory name encodes the path the session ran in. We derive the
    # key from the resolved repo_root the same way the harness does.
    repo_key = repo_root.replace("/", "-")
    base = os.path.join(home, ".claude", "projects", repo_key)
    if not os.path.isdir(base):
        return {}

    pattern = re.compile(r"tasks/(\d{3})-")
    agg: dict[str, dict[str, int]] = defaultdict(
        lambda: {"in": 0, "out": 0, "cache_read": 0,
                 "cache_create": 0, "sessions": 0}
    )

    for path in sorted(glob.glob(os.path.join(base, "*.jsonl"))):
        last_prompt = ""
        in_tok = out_tok = cr = cc = 0
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if rec.get("type") == "last-prompt":
                    last_prompt = rec.get("lastPrompt", "") or ""
                    continue
                if rec.get("type") != "assistant":
                    continue
                msg = rec.get("message")
                if isinstance(msg, str):
                    # `message` is a python-repr string (single-quoted dict),
                    # not JSON. ast.literal_eval recovers it. If the format
                    # ever shifts to JSON we accept that too.
                    try:
                        msg = ast.literal_eval(msg)
                    except (ValueError, SyntaxError):
                        continue
                if not isinstance(msg, dict):
                    continue
                u = msg.get("usage")
                if not isinstance(u, dict):
                    continue
                in_tok += u.get("input_tokens", 0) or 0
                out_tok += u.get("output_tokens", 0) or 0
                cr += u.get("cache_read_input_tokens", 0) or 0
                cc += u.get("cache_creation_input_tokens", 0) or 0

        m = pattern.search(last_prompt)
        if not m:
            continue
        tid = m.group(1)
        b = agg[tid]
        b["in"] += in_tok
        b["out"] += out_tok
        b["cache_read"] += cr
        b["cache_create"] += cc
        b["sessions"] += 1

    return dict(agg)


# --- report rendering -------------------------------------------------------


def fmt_ts(ts: datetime | None) -> str:
    if ts is None:
        return "—"
    return to_display(ts).strftime("%m-%d %H:%M")


def build_table(rows: list[dict[str, Any]], totals: dict[str, Any],
                include_tokens: bool) -> str:
    headers = ["task", "state", "queue→claim", "impl", "review",
               "rounds", "review→merged", "end-to-end", "flags"]
    if include_tokens:
        headers.extend(["in_tok", "out_tok", "sess"])

    widths = [len(h) for h in headers]
    str_rows: list[list[str]] = []
    for r in rows:
        cells = [
            r["task"],
            r["final_state"],
            fmt_duration(r["queue_to_claim"]),
            fmt_duration(r["impl_seconds"]),
            fmt_duration(r["review_seconds"]),
            str(r["review_rounds"]),
            fmt_duration(r["final_seconds"]),
            (fmt_duration(r["end_to_end"]) +
             ("*" if r.get("end_to_end_open") else "")),
            ",".join(r["flags"]) or "—",
        ]
        if include_tokens:
            t = r.get("tokens") or {}
            cells.extend([
                f"{t.get('in', 0):,}" if t else "N/A",
                f"{t.get('out', 0):,}" if t else "N/A",
                str(t.get("sessions", 0)) if t else "N/A",
            ])
        str_rows.append(cells)
        for i, c in enumerate(cells):
            if len(c) > widths[i]:
                widths[i] = len(c)

    def line(cells: list[str]) -> str:
        return "  ".join(c.ljust(widths[i]) for i, c in enumerate(cells))

    out: list[str] = []
    out.append(line(headers))
    out.append(line(["-" * w for w in widths]))
    out.extend(line(r) for r in str_rows)
    out.append("")

    # Summary block
    out.append(f"tasks        : {totals['n_tasks']}")
    out.append(f"merged       : {totals['n_merged']}")
    out.append(f"in-flight    : {totals['n_inflight']}")
    if totals["first_queue"]:
        out.append(
            f"window       : {fmt_ts(totals['first_queue'])} → "
            f"{fmt_ts(totals['last_queue'])}  "
            f"({fmt_duration(totals['window_seconds'])})"
        )
    out.append(
        f"throughput   : {totals['throughput_per_day']} tasks/day "
        f"(over {totals['window_days']}d)"
    )
    out.append(f"avg e2e      : {fmt_duration(totals['avg_e2e'])}")
    out.append(f"rework rate  : {totals['rework_rate']*100:.0f}% "
               f"({totals['n_rework']}/{totals['n_tasks']})")
    out.append(f"stuck rate   : {totals['stuck_rate']*100:.0f}% "
               f"({totals['n_stuck']}/{totals['n_tasks']})")
    out.append(f"rollbacks    : {totals['n_rollbacks']} (extra claim events)")
    out.append(f"unstucks     : {totals['n_unstucks']} (manual recovery commits)")
    if include_tokens:
        out.append(
            f"tokens (Σ)   : in={totals['sum_in']:,}  "
            f"out={totals['sum_out']:,}  "
            f"cache_read={totals['sum_cr']:,}  "
            f"sessions={totals['sum_sessions']}"
        )
    out.append("")
    out.append("* end-to-end is open when the task has not yet merged (queue → now).")
    out.append("  Anomalies flagged with `*` on individual cells indicate negative")
    out.append("  durations (clock weirdness) or open windows — not a hard error.")

    return "\n".join(out)


def build_json(rows: list[dict[str, Any]], totals: dict[str, Any],
               include_tokens: bool) -> str:
    def clean(v: Any) -> Any:
        if isinstance(v, datetime):
            return to_display(v).isoformat()
        if isinstance(v, dict):
            return {k: clean(x) for k, x in v.items()}
        if isinstance(v, list):
            return [clean(x) for x in v]
        return v
    payload = {
        "tasks": [clean(r) for r in rows],
        "summary": clean(totals),
        "include_tokens": include_tokens,
    }
    return json.dumps(payload, indent=2, ensure_ascii=False)


def build_md(rows: list[dict[str, Any]], totals: dict[str, Any],
             include_tokens: bool) -> str:
    headers = ["task", "state", "queue→claim", "impl", "review",
               "rounds", "review→merged", "end-to-end", "flags"]
    if include_tokens:
        headers.extend(["in_tok", "out_tok", "sess"])
    lines = ["| " + " | ".join(headers) + " |",
             "|" + "|".join("---" for _ in headers) + "|"]
    for r in rows:
        cells = [
            r["task"], r["final_state"],
            fmt_duration(r["queue_to_claim"]),
            fmt_duration(r["impl_seconds"]),
            fmt_duration(r["review_seconds"]),
            str(r["review_rounds"]),
            fmt_duration(r["final_seconds"]),
            fmt_duration(r["end_to_end"]) + ("*" if r.get("end_to_end_open") else ""),
            ",".join(r["flags"]) or "—",
        ]
        if include_tokens:
            t = r.get("tokens") or {}
            cells.extend([
                f"{t.get('in', 0):,}" if t else "N/A",
                f"{t.get('out', 0):,}" if t else "N/A",
                str(t.get("sessions", 0)) if t else "N/A",
            ])
        lines.append("| " + " | ".join(cells) + " |")
    lines.append("")
    lines.append(f"**summary** — tasks={totals['n_tasks']}, merged={totals['n_merged']}, "
                 f"throughput={totals['throughput_per_day']}/day, "
                 f"avg e2e={fmt_duration(totals['avg_e2e'])}, "
                 f"rework={totals['rework_rate']*100:.0f}%, "
                 f"stuck={totals['stuck_rate']*100:.0f}%")
    if include_tokens:
        lines.append(
            f"**tokens (Σ)** — in={totals['sum_in']:,} · "
            f"out={totals['sum_out']:,} · "
            f"cache_read={totals['sum_cr']:,} · "
            f"sessions={totals['sum_sessions']}"
        )
    return "\n".join(lines)


# --- main --------------------------------------------------------------------


def find_repo_root(start: str) -> str:
    """Walk up from `start` until we find a directory that contains a `.git`
    entry. Falls back to `start` if nothing is found (which then makes
    `git -C` fail loudly — preferable to silent mis-targeting)."""
    cur = os.path.abspath(start)
    while True:
        if os.path.isdir(os.path.join(cur, ".git")):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            return os.path.abspath(start)
        cur = parent


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        prog="stats.py",
        description=(
            "pipeline-bus analytics — git-archaeology report. "
            "Reads commit history (no protocol touched) and renders "
            "per-task stage timing; supports an opt-in token-attribution "
            "column sourced from the local Claude session jsonl."
        ),
    )
    fmt = p.add_mutually_exclusive_group()
    fmt.add_argument("--json", action="store_true", help="emit machine JSON")
    fmt.add_argument("--md", action="store_true",
                     help="emit a markdown table suitable for the README")
    p.add_argument("--tokens", action="store_true",
                   help="augment with per-task token counts from jsonl")
    p.add_argument("--repo", default=os.getcwd(),
                   help="path to the bus checkout (default: current dir)")
    p.add_argument(
        "--tz", default=None, type=float,
        help="display-timezone UTC offset in hours (e.g. 9, -5, 0). "
             "Overrides system local and PIPELINE_TZ.",
    )
    args = p.parse_args(argv)

    if args.tz is not None:
        _display_tz.override = timezone(timedelta(hours=args.tz))

    repo_root = find_repo_root(args.repo)
    if not os.path.isdir(os.path.join(repo_root, ".git")):
        print(f"error: {repo_root} is not a git repository", file=sys.stderr)
        return 2

    rows_raw = git_log(repo_root)
    events: list[Event] = []
    for ts, _author, msg in rows_raw:
        events.extend(parse_message(msg, ts))

    timelines = build_timelines(events)
    now = datetime.now(_display_tz())

    task_ids = sorted(timelines.keys())
    rows: list[dict[str, Any]] = []
    for tid in task_ids:
        tl = timelines[tid]
        m = compute_metrics(tl, now)
        flags: list[str] = []
        if m["rollback_count"]:
            flags.append(f"rollback×{m['rollback_count']}")
        if m["unstuck_count"]:
            flags.append(f"unstuck×{m['unstuck_count']}")
        if m["live_fire_count"]:
            flags.append(f"live-fire×{m['live_fire_count']}")
        if m["stuck_occurred"]:
            flags.append("stuck")
        if m["end_to_end_open"]:
            flags.append("in-flight")
        rows.append({
            "task": tid,
            "final_state": m["final_state"],
            "queue_to_claim": m["queue_to_claim"],
            "impl_seconds": m["impl_seconds"],
            "review_seconds": m["review_seconds"],
            "review_rounds": m["review_rounds"],
            "final_seconds": m["final_seconds"],
            "end_to_end": m["end_to_end"],
            "end_to_end_open": m["end_to_end_open"],
            "flags": flags,
        })

    token_data: dict[str, dict[str, int]] = {}
    if args.tokens:
        token_data = collect_task_tokens(repo_root)
    if args.tokens:
        for r in rows:
            r["tokens"] = token_data.get(r["task"])

    # Aggregate / summary
    merged_rows = [r for r in rows if r["final_state"] == "merged"]
    in_flight = [r for r in rows if r["end_to_end_open"]]
    rework_rows = [r for r in rows if r["review_rounds"] >= 2]
    stuck_rows = [r for r in rows if "stuck" in r["flags"]]

    e2e_values = [r["end_to_end"] for r in merged_rows if r["end_to_end"] is not None]
    avg_e2e = (sum(e2e_values) / len(e2e_values)) if e2e_values else None

    queue_times = [tl.queue for tl in timelines.values() if tl.queue]
    first_queue = min(queue_times) if queue_times else None
    last_queue = max(queue_times) if queue_times else None
    window_seconds = (
        seconds_between(first_queue, last_queue) if first_queue and last_queue else None
    )
    window_days = (window_seconds / 86400.0) if window_seconds else None
    throughput_per_day = (
        round(len(task_ids) / window_days, 2) if window_days and window_days > 0 else 0
    )

    totals = {
        "n_tasks": len(task_ids),
        "n_merged": len(merged_rows),
        "n_inflight": len(in_flight),
        "n_rework": len(rework_rows),
        "n_stuck": len(stuck_rows),
        "n_rollbacks": sum(
            compute_metrics(timelines[t], now)["rollback_count"] for t in task_ids
        ),
        "n_unstucks": sum(timelines[t].unstuck_count for t in task_ids),
        "first_queue": first_queue,
        "last_queue": last_queue,
        "window_seconds": window_seconds,
        "window_days": round(window_days, 2) if window_days else None,
        "throughput_per_day": throughput_per_day,
        "avg_e2e": avg_e2e,
        "rework_rate": (len(rework_rows) / len(task_ids)) if task_ids else 0,
        "stuck_rate": (len(stuck_rows) / len(task_ids)) if task_ids else 0,
        "sum_in": sum(t.get("in", 0) for t in token_data.values()),
        "sum_out": sum(t.get("out", 0) for t in token_data.values()),
        "sum_cr": sum(t.get("cache_read", 0) for t in token_data.values()),
        "sum_sessions": sum(t.get("sessions", 0) for t in token_data.values()),
    }

    if args.json:
        print(build_json(rows, totals, args.tokens))
    elif args.md:
        print(build_md(rows, totals, args.tokens))
    else:
        print(build_table(rows, totals, args.tokens))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())