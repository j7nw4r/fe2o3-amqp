# AMQP 1.0 conformance process

A two-half process that walks the OASIS AMQP 1.0 standard section by section,
records whether this codebase conforms, files a tree of GitHub issues for the
gaps, and then works that tree to merged pull requests.

The two halves run on their own or together:

| Command | What it does |
|---|---|
| `/spec-audit` | Reads specification sections, judges the code, files issues |
| `/spec-fix` | Takes one issue from the tree to a merged pull request |
| `/spec-compliance` | Alternates the two and reports the rollup |

The original statement of need is in [`PROMPT.md`](PROMPT.md). Edit that file
when the requirements change, then change this design to match.

## The work-list

`manifest.json` holds 164 units, one for each leaf section of the standard.

| Part | Units |
|---|---:|
| 1, Types | 39 |
| 2, Transport | 61 |
| 3, Messaging | 37 |
| 4, Transactions | 15 |
| 5, Security | 12 |

Each unit carries its id, title, the deep link to its anchor in the OASIS HTML,
its kind (`prose`, `type`, `constants`), its parent section, whether it is
normative, and a list of code surfaces to start reading from.

`bin/gen-manifest.py` builds the file by parsing the table of contents out of
the five specification documents. The anchors are extracted, not guessed. Never
edit `manifest.json` by hand; edit the generator and run it again.

`surfaces.json` is the curated half: it maps a specification id prefix to the
crates and modules that implement it, longest prefix wins. It is the single
highest-value file here, because it saves every investigator from rediscovering
the crate layout. Keep it current when modules move. Every path in it is
checked against the tree when the manifest regenerates.

```sh
python3 docs/spec-audit/bin/gen-manifest.py
```

## The ledger

The ledger answers one question: which units are audited, and what did the
audit find. It is what makes the process idempotent and resumable.

It lives on the orphan branch `spec-audit`, checked out as a linked worktree at
`.claude/worktrees/spec-audit-ledger`. An orphan branch keeps `main` clean, so
a rebase onto `upstream/main` never touches audit state.

```
spec-audit branch
  ledger/<id>.json      one audit record for each unit
  statements/<id>.json  cached normative statements from the reader
  tree.json             issue numbers for the root, part, and section trackers
  STATUS.md             generated rollup
```

One file for each unit, on purpose. Two agents auditing different units never
write the same file, so a parallel run does not conflict.

### The audit record

```json
{
  "id": "2.6.7",
  "title": "Flow Control",
  "status": "conformant | violations-filed | not-applicable | blocked",
  "audited_at": "2026-08-20T15:04:05Z",
  "code_sha": "4df72b3c...",
  "statements": 11,
  "findings": [{"issue": 42, "title": "...", "severity": "must", "claim": "statement 1"}],
  "uncertain": [{"n": 7, "question": "...", "would_need": "..."}],
  "notes": "one paragraph, SHOULD deviations and test gaps included",
  "auditor": "spec-investigator"
}
```

### The idempotency contract

- A unit with a record is skipped. That is the resume mechanism, and it holds
  across machines because the branch is pushed.
- `--recheck` re-audits a recorded unit **only** when `code_sha` no longer
  matches `HEAD`. A unit audited against the current code is never redone.
- The record is written **after** the issues are filed. A crash between the two
  leaves the unit unrecorded, so the next run redoes it. Redoing a unit costs a
  little; a recorded unit whose issues were never filed is a silent hole.
- A clean verdict is recorded like any other. Without that record the next run
  audits the same conformant section again.

### The tools

```sh
docs/spec-audit/bin/ledger.sh init          # create or attach the worktree
docs/spec-audit/bin/ledger.sh next --count 5 [--part transport] [--recheck]
docs/spec-audit/bin/ledger.sh show 2.6.7    # manifest entry
docs/spec-audit/bin/ledger.sh get 2.6.7     # audit record
docs/spec-audit/bin/ledger.sh put 2.6.7 < record.json
docs/spec-audit/bin/ledger.sh statements get|put 2.6.7
docs/spec-audit/bin/ledger.sh status        # regenerate STATUS.md
```

`SPEC_AUDIT_NO_PUSH=1` batches the pushes; call `ledger.sh push` at the end.

## The issue tree

Native GitHub sub-issues, four levels deep. GitHub allows 100 sub-issues under
one parent and eight levels of nesting, so the shape has room.

```
#1  AMQP 1.0 conformance audit                    [spec-audit, spec-tracking]
    #2  Part 2: Transport conformance             [spec-part/transport]
        #7  [2.6] Links
            #8  [2.6.7] Sender keeps transferring past zero link-credit
            #9  [2.6.13] Delivery resumption ignores the unsettled map
```

A section tracker is created the first time that section produces a finding, so
a clean section makes no issue at all. Only the leaves are units of work; the
`spec-tracking` label marks the three tracker levels and keeps them out of
`tree.sh ready`.

The precise specification id lives in the issue title as `[2.6.7]` and in the
body, not in a label. 164 labels would be unusable; a title prefix is greppable
and reads well in a list.

### Labels

| Label | Meaning |
|---|---|
| `spec-audit` | Belongs to the conformance tree |
| `spec-tracking` | A tracker node, not a unit of work |
| `spec-part/<slug>` | Which part of the standard |
| `sev/must` | Violates a normative MUST or MUST NOT |
| `sev/mandatory-missing` | A mandatory field, type, or behavior is absent |
| `spec-fix/in-progress` | A fix run holds this issue |

`spec-fix/in-progress` is the lock that lets several fix runs work at once
without two of them taking the same issue.

### The tools

```sh
docs/spec-audit/bin/tree.sh bootstrap       # labels, root, five part trackers
docs/spec-audit/bin/tree.sh dupes 2.6.7 link credit
docs/spec-audit/bin/tree.sh file finding.json
docs/spec-audit/bin/tree.sh ready --count 10
docs/spec-audit/bin/tree.sh wip             # open pull requests, against the cap
docs/spec-audit/bin/tree.sh claim 42 | release 42
docs/spec-audit/bin/tree.sh children 7
```

`bootstrap` is idempotent: it adopts what a previous run created, matching on
the exact issue title. Environment overrides: `SPEC_AUDIT_REPO`,
`SPEC_AUDIT_UPSTREAM`, `SPEC_AUDIT_WIP_CAP`.

The sub-issue API takes an issue **database id**, not an issue number. `tree.sh`
hides that; call the API through it rather than by hand.

## The validation half

```
/spec-audit [--part <n|slug>] [--section <id>] [--count <k>] [--recheck] [dry-run]
```

For each unit, in sequence:

1. **`spec-reader`** fetches the section and extracts its normative statements
   verbatim, plus the field table for a type. Its output is cached on the
   ledger branch, because the standard does not change.
2. **`spec-investigator`** reads the code at the surfaces the manifest names,
   gives every statement a verdict with `file:line` evidence, checks the
   candidates `tree.sh dupes` returned, and files one issue for each violation.
3. The command reads the cited lines itself before it believes any `violation`,
   and spot-checks a `conformant` verdict. Then it writes the ledger record.

Units run one at a time. Two investigators filing at once race on the duplicate
check and on section-tracker creation, and the tree grows two issues for one
defect.

### The filing bar

File an issue for exactly two things:

- A violated **MUST** or **MUST NOT**.
- An **absent mandatory** field, type, or behavior.

Everything else goes in the record's `notes` and produces no issue: SHOULD and
MAY deviations, correct-but-untested behavior, and style. Seven units are
marked informative in the manifest and close as `not-applicable` without an
investigation pass.

The bar is narrow on purpose. It is set in `gen-manifest.py`, in the agent
files, and in `/spec-audit`; change all three together.

### Verdicts

| Verdict | Files an issue? |
|---|---|
| `conformant` | no |
| `violation` | yes, `sev/must` |
| `absent` | yes, `sev/mandatory-missing` |
| `not-applicable` | no; a deliberate scope choice, named in `notes` |
| `uncertain` | no; surfaced to the user in the report |

`uncertain` is a required answer, not a failure. A guess dressed as a verdict
sends the fix pipeline after a phantom, which costs more to undo than the
question costs to ask. Every finding also needs a reproduction sketch: the
input, what the standard requires, what the code does. No sketch means the
finding was never established, so it becomes `uncertain`.

## The implementation half

```
/spec-fix [<issue>] [--count <k>] [--draft-only] [--part <n|slug>] [dry-run]
```

1. Check the cap. **Five open pull requests, hard.** At the cap the run stops
   and reports which pull requests need a human.
2. Pick the next ready leaf: `sev/mandatory-missing` first, then `sev/must`,
   then by number. Claim it with the lock label.
3. Read the issue, its section tracker, and **fetch the specification link**.
   The issue is a summary another agent wrote; the standard is the requirement.
4. Delegate the whole implementation to `/ship-task <n> --yolo`, which runs its
   own eight-agent team in its own worktree: requirements, research, test
   design, a red proof, implementation, validation on a different model, and a
   draft pull request.
5. Check the work: read the diff, and prove the new test fails without the
   source change by stashing the source hunk.
6. Drive CI green, then mark ready and merge with a squash.
7. When a section tracker's last child closes, re-audit that section with
   `--recheck` rather than assuming. A clean re-audit closes the tracker; a
   re-audit that files new issues leaves it open, which is correct.

The test must pin the **specification requirement**, with the section id quoted
in the test name or a comment above it. A test written from the code under test
passes on the bug.

### Why this half merges

The standing rule everywhere else is drafts only. This pipeline is the stated
exception, because the process was asked for as one that drives an issue to
merge, and a five pull request cap only works when work drains. `--draft-only`
puts the old behavior back for a run.

## Running both

```
/spec-compliance [--audit <k>] [--fix <k>] [--rounds <n>] [--part <n|slug>]
```

Alternates the halves and stops when the cap blocks progress, when a round
neither files nor merges anything, or when either half stops to ask a question.

Never run the two halves at the same time. The audit records the sha it read;
the fix half moves that sha underneath, and the records then describe code that
no longer exists.

## First run

```sh
gh repo edit j7nw4r/fe2o3-amqp --enable-issues   # forks ship with issues off
python3 docs/spec-audit/bin/gen-manifest.py
docs/spec-audit/bin/ledger.sh init
docs/spec-audit/bin/tree.sh bootstrap
```

Then audit one part in a small batch and read what comes out before you scale
up:

```
/spec-audit --part security --count 3
```

Part 5 is the smallest at 12 units and has the clearest requirements, so it is
the cheapest place to find out whether the filing bar is set where you want it.

## Files

| Path | What it is |
|---|---|
| `docs/spec-audit/README.md` | This design |
| `docs/spec-audit/PROMPT.md` | The original statement of need |
| `docs/spec-audit/manifest.json` | Generated work-list, 164 units |
| `docs/spec-audit/surfaces.json` | Curated specification-to-code map |
| `docs/spec-audit/bin/gen-manifest.py` | Builds the manifest from the OASIS HTML |
| `docs/spec-audit/bin/ledger.sh` | Ledger and work-list queries |
| `docs/spec-audit/bin/tree.sh` | Issue tree, labels, locks, cap |
| `.claude/agents/spec-reader.md` | Extracts normative statements |
| `.claude/agents/spec-investigator.md` | Judges the code, files issues |
| `.claude/commands/spec-audit.md` | The validation half |
| `.claude/commands/spec-fix.md` | The implementation half |
| `.claude/commands/spec-compliance.md` | Runs both |

## Known limits

- **The audit reads code, not behavior.** An investigator judges the source. It
  does not run a broker or replay frames. A finding that needs a live peer to
  settle comes back as `uncertain`, and that is the honest answer.
- **`surfaces.json` rots.** When a module moves, the hint sends the
  investigator to the wrong place. The path check in `gen-manifest.py` catches a
  deleted path; it cannot catch a stale one that still exists.
- **The upstream fork drifts.** Findings are filed against `j7nw4r/fe2o3-amqp`.
  Anything worth sending to `minghuaw/fe2o3-amqp` is a separate decision, and
  nothing here makes it.
- **A clean audit is not a conformance claim.** It records that one agent read
  the code against the quoted requirements and found nothing. That is weaker
  than a test suite and much weaker than an interoperability run.
