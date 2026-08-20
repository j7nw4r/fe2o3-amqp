---
name: spec-compliance
description: Run both halves of the AMQP 1.0 conformance process in one loop. Audits specification sections until the issue tree has work, then works the tree until the open pull request cap is hit, then audits again. Use it to make progress unattended; use /spec-audit or /spec-fix when you want one half on its own.
argument-hint: [--audit <k>] [--fix <k>] [--rounds <n>] [--part <n|slug>] [--draft-only] [dry-run]
allowed-tools: Skill, Agent, SendMessage, Read, Glob, Grep, AskUserQuestion, Bash(git:*), Bash(gh:*), Bash(docs/spec-audit/bin/*), Bash(python3:*), Bash(cargo:*), Bash(date:*)
---

# Run the whole conformance process

This skill is a scheduler. It holds no logic of its own: it alternates
`/spec-audit` and `/spec-fix` and stops on the conditions below. The design
lives in `docs/spec-audit/README.md`.

Run the halves on their own when you want to steer:

- `/spec-audit` alone builds the issue tree and files nothing else.
- `/spec-fix` alone works the tree that already exists.

## Arguments

- `--audit <k>`: specification units for each audit phase. Default `5`.
- `--fix <k>`: issues for each fix phase. Default `2`.
- `--rounds <n>`: audit-then-fix rounds in this invocation. Default `1`.
- `--part <n|slug>`: hold both halves to one specification part.
- `--draft-only`: pass through to `/spec-fix`, so nothing merges.
- `dry-run`: report what each phase would take and stop.
- Any other token: stop and ask what it means.

## Step 0: Report the state before you start

```sh
docs/spec-audit/bin/ledger.sh init >/dev/null
docs/spec-audit/bin/ledger.sh sync
docs/spec-audit/bin/ledger.sh status
docs/spec-audit/bin/tree.sh wip
docs/spec-audit/bin/tree.sh ready --count 5
```

Print: units audited out of 164, open findings, open pull requests against the
cap of five, and the next issues in line. On `dry-run`, stop here.

## The round

Repeat `--rounds` times.

### Phase A: audit

```
/spec-audit --count <k> [--part <p>]
```

Skip this phase when the ledger reports every unit in scope audited. Say so
rather than running an audit that returns nothing.

### Phase B: fix

```
/spec-fix --count <k> [--part <p>] [--draft-only]
```

Skip this phase when `tree.sh wip` is already at the cap. Say which pull
requests are holding the cap.

### Between rounds

Print one line: units audited this round, issues filed, issues merged, open
pull requests. Then check the stop conditions.

## Stop conditions

Stop the whole run, report, and do not start another round when any of these
is true:

- The open pull request count is at the cap and no pull request moved during
  the last fix phase. More rounds cannot help; the user has to merge or close
  something.
- An audit phase filed nothing and a fix phase merged nothing. The process is
  not making progress and something is wrong.
- Any phase stopped to ask a question. Surface the question; never answer it on
  the user's behalf to keep the loop running.
- The working tree is dirty or `main` is red.

## Final report

Give the user, in this order:

- The rollup: units audited out of 164, issues open in the tree, issues merged.
- Every issue filed this run, with its URL.
- Every pull request opened or merged this run, with its URL and state.
- Every `uncertain` verdict any investigator returned. These need the user's
  judgment and are the reason to read the report.
- Open pull requests against the cap.
- What a following invocation would take next.

## Rules

- **Audit before fix in each round.** A fresh tree means the fix phase always
  has the newest findings to choose from.
- **Never run the two halves at once.** The audit half reads the code at a sha
  and records it; the fix half moves that sha underneath. Overlapping them
  produces ledger records that describe code that no longer exists.
- **The cap is the cap.** Five open pull requests, checked before every fix
  phase.
- **Stop on a question.** An unattended loop that guesses at an ambiguous
  specification reading fills the tree with noise, which costs more to undo
  than to do.
