---
name: spec-fix
description: Take one issue from the AMQP 1.0 conformance tree from open to merged. Picks the next ready leaf, delegates the implementation to /ship-task, drives CI green, merges, and re-audits the section when its last child closes. Never lets more than five pull requests stay open at once. Add dry-run to pick and report without changing anything, or an issue number to force one.
argument-hint: [<issue-number>] [--count <k>] [--draft-only] [--part <n|slug>] [dry-run]
allowed-tools: Agent, SendMessage, Skill, Read, Glob, Grep, AskUserQuestion, Bash(git:*), Bash(gh:*), Bash(docs/spec-audit/bin/*), Bash(python3:*), Bash(cargo:*), Bash(ls:*), Bash(cat:*), Bash(date:*)
---

# Work the AMQP 1.0 conformance tree

One invocation takes one issue from open to merged, then stops. Wrap it in
`/loop` to crawl the tree.

This is the implementation half of the process. The validation half is
`/spec-audit`. Both halves run on their own, and `/spec-compliance` runs them
together. The design lives in `docs/spec-audit/README.md`.

## Constants

| Thing | Value |
|---|---|
| Repository | `j7nw4r/fe2o3-amqp` |
| Base branch | `main` |
| Open pull request cap | **5**. This is a hard stop, not a target. |
| Tree tool | `docs/spec-audit/bin/tree.sh` |
| Ledger tool | `docs/spec-audit/bin/ledger.sh` |
| Implementation | `/ship-task`, which owns the whole design-to-draft-PR run |
| Check suite | see step 4 |

Pass `--repo j7nw4r/fe2o3-amqp` to every bare `gh` call.

## Arguments

- A bare number: work that issue instead of the computed next one. Still
  refuse it when it is a tracker or another run holds it, and say so.
- `--count <k>`: work up to `k` issues in this run, in sequence. Default `1`.
  The pull request cap still applies and stops the run early when it is hit.
- `--draft-only`: stop at a green draft pull request and do not merge. Use it
  when you want to read the change before it lands.
- `--part <n|slug>`: restrict the pick to one specification part.
- `dry-run` (aliases `dryrun`, `-n`): do steps 0 and 1, report the issue a real
  run would take, and stop. No branch, no commit, no push, no comment.
- Any other token: stop and ask what it means. Do not guess.

**The default merges.** The user asked for a pipeline that drives an issue to
merge, and the five pull request cap only makes sense when work drains. This
overrides the standing drafts-only rule for this pipeline and for nothing else.
`--draft-only` puts the old behavior back.

## Step 0: Preflight

```sh
git -C . checkout main && git -C . pull --ff-only && git -C . status --short
docs/spec-audit/bin/tree.sh wip
```

- The working tree must be clean. If it is not, stop and report the diff. Never
  stash, reset, or discard the user's work.
- **The cap.** If `wip` prints `5` or more, stop. Do not start new work. Report
  each open pull request with its CI state and say which one needs a human.
  Offer to drive an existing pull request to green instead, and let the user
  choose. Starting a sixth is never the right move.
- `main` must be green before you start. A red base is a stop, not something to
  fix inside this run.

## Step 1: Pick the issue

```sh
docs/spec-audit/bin/tree.sh ready --count 10
```

Each line is the issue number, its severity label, and the title. The list is
already ordered: `sev/mandatory-missing` before `sev/must`, then by number.
Trackers and issues another run holds are already filtered out.

Take the first line. Report the rest, because a parallel run may take them.

If the list is empty, say what is left: how many tracker issues remain open,
how many units the ledger still has unaudited, and whether `/spec-audit` should
run first.

Then read, in this order: the issue body, the parent section tracker, and the
specification section the body links. **Fetch that link.** The issue is a
summary written by another agent; the specification is the requirement.

Claim it, so a parallel run skips it:

```sh
docs/spec-audit/bin/tree.sh claim <n>
```

On `dry-run`, stop here without claiming.

## Step 2: Implement

Delegate the whole implementation to the existing skill:

```
/ship-task <n> --yolo
```

`/ship-task` runs its own team in its own git worktree: it restates the issue
as requirements, researches the outside facts, designs the tests, proves them
red, implements, validates on a different model, and opens the draft pull
request. Do not reimplement any of that here, and do not second-guess its
worktree.

Two things this pipeline adds on top:

- Tell `/ship-task` the specification section id and its deep link, and require
  that the test pins the **specification requirement**, not the current code.
  A test written from the implementation passes on the bug.
- Require that the change stays inside the one defect. A second defect found on
  the way is a new issue, filed against the same section tracker, not extra
  scope in this pull request.

If `/ship-task` fails or stops with questions it cannot settle, release the
claim and report. Do not paper over it:

```sh
docs/spec-audit/bin/tree.sh release <n>
```

## Step 3: Check the work yourself

`/ship-task` returns a report. A report is a claim. Before you drive the pull
request anywhere:

- Read the diff.
- Read the new test and satisfy yourself it fails without the source change.
  `git stash` the source hunk, run the test, see it fail, restore. If the test
  passes without the fix, the test is wrong and the run goes back to step 2.
- Read the specification quote in the issue against the new behavior.

## Step 4: Drive CI

```sh
gh pr checks <pr> --repo j7nw4r/fe2o3-amqp --watch
```

The suite is `cargo fmt --all -- --check`, `cargo clippy --all -- --deny warnings`,
`cargo make feature_check` in `fe2o3-amqp`, and `cargo make test` in each
crate. Reproduce a failure locally before you change anything.

Two known traps in this repository:

- `cargo fmt` does not reach `fe2o3-amqp-ws/src/native.rs` or `wasm.rs`, since
  a macro hides their `mod` declarations. Format those two by hand.
- The examples check fails when it runs from a `.claude/worktrees` worktree.
  Copy the tree somewhere outside the repository and run it there.

Loop until green. Report every failure and what fixed it.

## Step 5: Merge

Skip this whole step on `--draft-only`; report the green draft and stop.

```sh
gh pr ready <pr> --repo j7nw4r/fe2o3-amqp
gh pr merge <pr> --repo j7nw4r/fe2o3-amqp --squash --delete-branch
```

Merge only when every check is green. A merge on a red or pending pull request
is a stop, and never use `--admin` to force one past a failing check.

The pull request body carries `Closes #<n>`, so GitHub closes the issue. Make
sure it did; close it by hand if it did not.

Then leave the worktree and clean it up:

```sh
git -C . worktree remove <worktree> && git -C . checkout main && git -C . pull --ff-only
```

## Step 6: Close the section when it empties

```sh
docs/spec-audit/bin/tree.sh children <section-tracker>
```

If every child is closed, the section may now be conformant. Re-audit it rather
than assuming:

```
/spec-audit --section <section-id> --recheck
```

A clean re-audit closes the tracker with a comment naming the sha it was
audited at. A re-audit that files new issues leaves the tracker open, which is
the correct outcome and not a failure.

Apply the same rule up the tree: a part tracker closes when all of its section
trackers are closed, and the root closes when all five parts are.

## Step 7: Report

Give the user: the issue, the pull request URL, the merge state, the branch and
worktree, the commits, the CI history including anything that went red, the
test that pins the requirement, every deviation `/ship-task` reported, any new
issue this run filed, the section tracker state, and the current open pull
request count against the cap of five.

## Rules

- **Five open pull requests, hard.** Check before every issue, including inside
  a `--count` loop. Stop at the cap; do not queue past it.
- **One issue for each pull request.** A pull request that fixes two issues
  hides a defect in review. Two defects means two runs.
- **The test comes from the specification.** Quote the requirement in the test
  name or a comment above it, with the section id. A test written from the code
  under test proves nothing.
- **Never force-push.** Not `--force`, not `--force-with-lease`, not on a branch
  this pipeline made. Ask first, every time.
- **Never merge red.** No `--admin`, no exceptions.
- **Release what you cannot finish.** An abandoned claim blocks the tree for
  every later run.
- **Report failure as failure.** A run that could not fix the issue says so and
  says why. Do not close the issue, and do not narrow it to make it look done.
