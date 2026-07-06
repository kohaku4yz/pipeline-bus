# Analytics

A self-contained, zero-intrusion stats lens for your pipeline. It reads
`git log` (no protocol code is touched) and rebuilds a per-task stage
report — `queue → claim → submit → verdict → merged` — purely from commit
timestamps and message patterns. A `--tokens` flag additionally pulls
per-session input / output / cache token counts from the local Claude
session jsonl so you can see how much each implementation round actually
cost.

The script lives at `analytics/stats.py` and uses only the Python
standard library — no `pip install`, no extra deps to add to `wsl/SETUP.md`
or `vps/SETUP.md`.

## Usage

Three commands, each one line. Run from the bus checkout root:

```bash
python3 analytics/stats.py           # terminal table (default)
python3 analytics/stats.py --md      # markdown table for the README
python3 analytics/stats.py --tokens  # append in_tok / out_tok / sess columns
```

The script auto-discovers the repo root by walking up to the nearest
`.git`, so you can run it from a subdirectory too. Display timezone
defaults to system local; override with `export PIPELINE_TZ=9` (or any
UTC-offset-in-hours) or `python3 analytics/stats.py --tz 9`.

## Example output (fictional demo data)

The table below is a **fictional** snapshot — task names, durations, and
token figures are illustrative only and bear no relation to any real
pipeline. The format matches a real run.

The `queue→claim` column shown populated here is the result of a
**custom dispatcher** that commits a `queue task NNN — <title>`
message at dispatch time. The shipped dispatcher only writes
`status/NNN.json` and does **not** emit that commit, so on a default
out-of-the-box checkout that column will render as `N/A` for every
task until you add a queue commit of your own (see `### Caveats`
below for the exact message shape the script looks for). Everything
else in the table populates from the shipped poller / reviewer.

Default terminal table (snippet):

```
task                        state   queue→claim  impl    review  rounds  review→merged  end-to-end  flags
-----                       ------  -----------  ------  ------  ------  -------------  ----------  -----
001-example-feature         merged  4m12s        7m38s   14m22s  1       1m18s          28m30s      —
002-example-doc-fix         merged  6m05s        12m49s  9m14s   1       42s            28m50s      —
003-example-bug-hunt        merged  5m51s        9m22s   11m40s  2       57s            1h12m       rework
004-example-script-refactor merged  3m48s        6m14s   8m03s   1       35s            18m40s      —
005-example-config-tweak    merged  8m27s        11m05s  13m48s  2       1m02s          1h25m       rework

tasks        : 5
merged       : 5
in-flight    : 0
throughput   : 5.30 tasks/day (over 0.94d)
avg e2e      : 46m36s
rework rate  : 40% (2/5)
stuck rate   : 0% (0/5)
```

With `--tokens`, each row grows three columns on the right (`in_tok`,
`out_tok`, `sess`) and the summary block grows a `tokens (Σ)` line.
With `--md`, the same table is emitted in GitHub-flavored markdown,
ready to paste into a changelog or weekly status.

## Why bother running it

The metrics that matter are the ones humans feel but never measure:

- **rework rate** — `rounds ≥ 2` over total. A high rate means
  implementations routinely ship with gaps a static review can catch.
  Catching those gaps costs a fraction of what catching them in
  production costs. Aim to drive this to single-digit percent over time.
- **review→merged** — how long a finished review sits before an Owner
  lands it. Often the longest single stage in a healthy pipeline.
- **end-to-end** — `queue → merged`. The headline number for cycle time.

The most useful single comparison the report makes available is
**one-shot vs reworked**: in real deployments, tasks that pass in a
single review round consume meaningfully less total token than tasks
that bounce back for a second round — the second round adds the full
cost of a fresh implementation session, plus the reviewer's, on top of
the first round. The `--tokens` column lets you put a number on that
delta. (Concrete numbers depend on prompt length and reviewer model; the
script reports raw `input_tokens` / `output_tokens` /
`cache_read_input_tokens`, not USD, so you can apply your own price
model without re-running the report.)

## Token attribution (`--tokens`)

When you opt in with `--tokens`, the script walks your local
`~/.claude/projects/` directory, opens every `<session>.jsonl` there,
and aggregates the `message.usage` field across all assistant turns in
that session.

**Project path convention.** Each Claude Code project is keyed by the
absolute working-directory path the session started in, with `/` replaced
by `-`. A session launched inside `/home/alice/code/my-project` lands
in `~/.claude/projects/-home-alice-code-my-project/`. The script
derives the same key for the bus checkout you point it at, so it works
for arbitrary locations without configuration.

**`usage` field shape.** Each assistant message carries a `usage` dict:

```json
{
  "input_tokens": 22300,
  "cache_creation_input_tokens": 0,
  "cache_read_input_tokens": 120,
  "output_tokens": 110
}
```

The script sums `input_tokens`, `output_tokens`,
`cache_read_input_tokens`, and `cache_creation_input_tokens` across
every assistant turn in a session, then attributes the session to a task
by parsing the final `lastPrompt` record for a `tasks/NNN-*.md`
reference. Sessions without that prompt pattern are skipped (e.g.
interactive debugging sessions).

**Graceful degradation.** If `~/.claude/projects/-<repo-key>/` does not
exist (a fresh clone that has never run the poller), `--tokens` still
runs — every task's token cells render as `N/A`, no exception, no
crash. Same behavior when individual jsonl files are malformed: that
file is skipped, the rest are summed.

## Caveats

- The report only sees the implementer host's session jsonl. If your
  reviewer and your Owner run on separate hosts, each host must run
  `stats.py --tokens` against the same checkout and you can `jq -s` the
  results to get a cross-host view.
- The shipped dispatcher's status update (write `status/NNN.json` +
  push) does **not** include a `queue task NNN`-style commit message,
  so the `queue→claim` column renders as `N/A`. If you want that cell
  populated, have your dispatch script commit the status change with a
  subject containing the literal word `queue` followed by `task NNN`.
  The pattern is documented at the top of `analytics/stats.py`.
- The script reads commits made by the shipped `poller.sh` and
  `reviewer_poll.sh`. If you fork those scripts and rename their
  commit subjects (e.g. drop the `(doing)` suffix), the matching regex
  in `analytics/stats.py` must be updated in lockstep — that mapping is
  effectively part of the protocol contract.
