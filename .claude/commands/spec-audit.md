---
name: spec-audit
description: Walk the OASIS AMQP 1.0 specification section by section and audit this codebase against it. Each section gets a reader agent that extracts its normative statements and an investigator agent that judges the code and files one GitHub issue for each MUST violation. Every verdict lands on the spec-audit ledger branch, so a run resumes where the last one stopped. Add dry-run to pick and report without changing anything.
argument-hint: [--part <n|slug>] [--section <id>] [--count <k>] [--recheck] [dry-run]
allowed-tools: Agent, Read, Glob, Grep, WebFetch, Bash(git:*), Bash(gh:*), Bash(docs/spec-audit/bin/*), Bash(python3:*), Bash(ls:*), Bash(cat:*), Bash(mktemp:*)
---

# Audit the codebase against AMQP 1.0

One invocation audits `--count` specification units and stops. Wrap it in
`/loop` to walk the whole standard.

This is the validation half of the process. The fix half is `/spec-fix`. Both
halves run on their own, and `/spec-compliance` runs them together. The design
lives in `docs/spec-audit/README.md`; read it when something here surprises you.

## Constants

| Thing | Value |
|---|---|
| Repository | `j7nw4r/fe2o3-amqp` |
| Work-list | `docs/spec-audit/manifest.json`, 164 units |
| Ledger branch | `spec-audit`, worktree `.claude/worktrees/spec-audit-ledger` |
| Ledger tool | `docs/spec-audit/bin/ledger.sh` |
| Tree tool | `docs/spec-audit/bin/tree.sh` |
| Filing bar | MUST, MUST NOT, and absent mandatory features. Nothing else. |

Pass `--repo j7nw4r/fe2o3-amqp` to every bare `gh` call. The working directory
changes between commands, so a bare `gh` can resolve against the wrong
repository.

## Arguments

- `--part <n|slug>`: audit only this part. `1`..`5`, or `types`, `transport`,
  `messaging`, `transactions`, `security`.
- `--section <id>`: audit only units under this section, such as `2.6`.
- `--count <k>`: how many units to audit in this run. Default `5`.
- `--recheck`: re-audit units already recorded, but only where the code moved
  since the record was written. Without it, a recorded unit is skipped.
- `dry-run` (aliases `dryrun`, `-n`): do steps 0 and 1, report the units a real
  run would take, and stop. No issue, no ledger write, no comment.
- Any other token: stop and ask what it means. Do not guess.

## Step 0: Preflight

```sh
git -C . status --short && git -C . rev-parse HEAD
docs/spec-audit/bin/ledger.sh init
docs/spec-audit/bin/ledger.sh sync
```

- The working tree must be clean. If it is not, stop and report the diff. Never
  stash, reset, or discard the user's work.
- `docs/spec-audit/manifest.json` must exist. If it does not, run
  `python3 docs/spec-audit/bin/gen-manifest.py`.
- The audit reads the code at `HEAD` and records that sha. Do not check out a
  different branch inside a run.
- On the first run ever, bootstrap the issue tree:
  ```sh
  docs/spec-audit/bin/tree.sh bootstrap
  ```
  It enables issues on the fork, creates the labels, and creates the root and
  the five part trackers. It is idempotent, so run it every time; a second run
  adopts what the first one made.

## Step 1: Pick the units

```sh
docs/spec-audit/bin/ledger.sh next --count <k> [--part <p>] [--section <s>] [--recheck]
```

Each line is `id`, part slug, title, and the surface hints, tab separated. An
empty list means the selected scope is fully audited; say so and stop.

Report the list before you work it. On `dry-run`, stop here.

## Step 2: Audit each unit

Work the units **one at a time**, in the order step 1 printed. Do not run two
investigators at once: two investigators filing at the same time race on the
duplicate check and on the section-tracker creation, and the tree then grows
two issues for one defect.

For each unit:

### 2a. The manifest entry

```sh
docs/spec-audit/bin/ledger.sh show <id>
```

An entry with `"normative": false` is informative prose. Skip the agents,
write a `not-applicable` record, and move to the next unit.

### 2b. The reader

Look for a cached extraction first, because the specification does not change:

```sh
docs/spec-audit/bin/ledger.sh statements get <id>
```

On a hit, use it. On a miss, spawn `spec-reader` with `model: "opus"` and give
it the manifest entry. Require its exact JSON reply. Then cache it:

```sh
docs/spec-audit/bin/ledger.sh statements put <id> < statements.json
```

An `informative_only: true` reply means the same as a non-normative manifest
entry: record `not-applicable` and move on.

### 2c. The duplicate check

Build two or three keywords from the unit title and the statement subjects,
then:

```sh
docs/spec-audit/bin/tree.sh dupes <id> <keywords>
```

Hand the whole output to the investigator. It is the investigator's job to
read the candidates and decide, not yours.

### 2d. The investigator

Spawn `spec-investigator` with `model: "opus"`. Give it the reader JSON, the
manifest entry, the `HEAD` sha, and the `dupes` output. Require its exact JSON
reply.

**Check its work before you trust it.** For every `violation` it reports, open
the file at the line it cited and read the code yourself. A verdict whose
citation does not say what the report claims is a defect in the report: send
the investigator back with what you found. Do not correct it yourself and do
not file the issue anyway.

Spot-check at least one `conformant` verdict for each unit. An investigator
that marks everything conformant without reading is the quiet failure this
step exists to catch.

### 2e. The ledger record

Write the record from the investigator's reply:

```sh
cat > /tmp/rec.json <<'EOF'
{"id": "<id>", "title": "<title>", "status": "<status>",
 "audited_at": "<iso8601 utc>", "code_sha": "<full HEAD sha>",
 "statements": <count>, "findings": [...], "uncertain": [...],
 "notes": "<one paragraph>", "auditor": "spec-investigator"}
EOF
docs/spec-audit/bin/ledger.sh put <id> < /tmp/rec.json
```

Get the timestamp from `date -u +%Y-%m-%dT%H:%M:%SZ`. Write the record even
when the verdict is clean: a `conformant` record is what makes the next run
skip the unit, and it is the whole resume mechanism.

Write the record **after** the issues are filed, so a crash between the two
leaves the unit unrecorded and the next run redoes it. Redoing a unit is
cheap; a recorded unit whose issues were never filed is a silent hole.

## Step 3: Close out

```sh
docs/spec-audit/bin/ledger.sh status
```

It regenerates `STATUS.md` on the ledger branch and pushes.

## Step 4: Report

Give the user, in this order:

- The units audited, with the verdict for each one.
- Every issue filed, as `#<n> <title>`, with its URL.
- Every finding matched to an existing issue instead of filed.
- Every `uncertain` entry, with what would settle it. Do not bury these; an
  uncertain reading is the thing most likely to need the user's judgment.
- The rollup line from `ledger.sh status`.
- The next units a following run would take.

## Rules

- **One writer at a time.** Audit units in sequence. The read side can fan out
  inside an investigator; the filing side cannot.
- **Never change source code.** This half of the process is read-only against
  the codebase. The only writes are GitHub issues and the ledger branch.
- **Quote the specification, never recall it.** The reader fetches the page
  every time it has no cache entry. A statement written from memory is the
  fastest way to a false issue.
- **The filing bar is narrow on purpose.** MUST, MUST NOT, and absent mandatory
  features. A SHOULD deviation goes in `notes`. A test gap goes in `notes`. The
  user set this bar; widening it is not yours to decide.
- **A finding needs a reproduction sketch.** Input or frame sequence, what the
  specification requires, what the code does. No sketch means it was never
  really established, so downgrade it to `uncertain`.
- **Record clean verdicts.** A section audited and found conformant is a
  result. Without the record the next run audits it again.
- **Do not close a tracker.** Section, part, and root trackers close when their
  children close, which is the fix pipeline's business.
