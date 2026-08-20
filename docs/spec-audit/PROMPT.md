# Statement of need

This file holds the original request for the AMQP 1.0 conformance process and
the decisions taken on top of it. Edit this file when the requirements change,
then change [`README.md`](README.md) and the skills to match.

Recorded 2026-08-20.

## The request, verbatim

> I would like to design a process which will will allow a team to iterate
> through the amqp 1.0 specification
> (https://docs.oasis-open.org/amqp/core/v1.0/os/amqp-core-overview-v1.0-os.html),
> section by section, to validate whether the fe2o3 codebase conforms. If it
> does not, I'd like to file a github issue against the j7nw4r fork. The end
> result should be a tree structure of github issues that need to be addressed
> to get fe2o3 into compliance.
>
> I envision this process:
>
> - Reader agent reads a section from the amqp 1.0 spec
> - The section contents are passed to an invesigation agent. The investigation
>   agent will explore and determine whether the codebase is compliant. If not,
>   it will file a github issue in the the issue tree. IT will make sure that
>   the issue it founds does not overlap with a previously files issue in the
>   tree.
>
> There will be a seperate team of agents which will be crawling and
> implementing the issue tree:
>
> - Agent will grab an issue from the tree.
> - Agent will determine what tests are needed to solidify the fix.
> - Agent will implement the issue fix.
> - Agent validates.
> - Agent pushes PR. Drives to merge.
>
> These two processes, spec validation and fix implementation, should be
> invokable either independently or together.
> The agents should also have an efficient way to record their process so that
> the process is idempotent and resumable.
>
> this prompt should also be saved in the repo so that I have the ability to
> refine the needs in the future.

## Decisions

Answered by the user when the process was designed.

| Question | Answer |
|---|---|
| Audit unit | The leaf subsection. 164 units, such as `2.6.7` and `5.3.3.2`. |
| Filing bar | Violated MUST or MUST NOT, and absent mandatory features. Nothing else. SHOULD and MAY deviations and test gaps are recorded but not filed. |
| Ledger location | The orphan branch `spec-audit`, so `main` stays clean for a rebase onto upstream. |
| Open pull requests | Never more than five at once. |

Taken by the assistant, with the reasoning:

| Decision | Why |
|---|---|
| Native GitHub sub-issues for the tree | The API is generally available and allows 100 children and eight levels. A checklist in a body is not queryable. |
| Root, part, section, finding: four levels | Section trackers appear only when a section produces a finding, so a clean section makes no issue. |
| Specification id in the title, not a label | 164 labels would be unusable. `[2.6.7]` is greppable and reads well in a list. |
| `/spec-fix` delegates to `/ship-task` | That skill already runs requirements, research, test design, a red proof, implementation, cross-model validation, and a draft pull request. Duplicating it would be 600 lines of drift. |
| The fix half merges by default | The request says "Drives to merge", and a five pull request cap only works when work drains. This overrides the standing drafts-only rule for this pipeline alone. `--draft-only` reverses it for a run. |
| Cached statement extraction | The standard does not change, so a re-audit pays for the code reading only. |

## Open questions

Things a future refinement should settle.

- **Upstreaming.** Findings are filed against `j7nw4r/fe2o3-amqp`. Nothing
  decides which fixes should go to `minghuaw/fe2o3-amqp`, or when.
- **Interoperability.** The audit reads source. It does not run a broker or
  replay frames, so a requirement that needs a live peer comes back
  `uncertain`. A conformance harness against a real broker would close that
  gap and is out of scope here.
- **Scope choices.** A section this library deliberately does not implement is
  `not-applicable`, and the investigator decides that case by case. A written
  scope statement would make the decision consistent instead.
- **The filing bar.** Set narrow to keep the tree honest. Widen it to SHOULD
  deviations or to test gaps by changing the bar in `.claude/agents/spec-investigator.md`,
  `.claude/commands/spec-audit.md`, and the README together.
