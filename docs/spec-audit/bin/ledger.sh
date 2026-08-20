#!/usr/bin/env bash
# Ledger for the AMQP 1.0 spec-audit pipeline.
#
# The ledger records which specification units are audited, what the verdict
# was, and which issues came out of each one. It lives on the orphan branch
# `spec-audit`, checked out as a linked worktree, so `main` stays clean for a
# rebase onto upstream.
#
# One file for each unit. Two agents that audit different units never touch
# the same file, so a parallel run does not conflict.
#
# Usage: docs/spec-audit/bin/ledger.sh <command> [args]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
AUDIT_DIR="$REPO_ROOT/docs/spec-audit"
MANIFEST="$AUDIT_DIR/manifest.json"
BRANCH="spec-audit"
WT="$REPO_ROOT/.claude/worktrees/spec-audit-ledger"

die() { echo "ledger: $*" >&2; exit 1; }

# --- worktree ---------------------------------------------------------------

cmd_init() {
  [ -f "$MANIFEST" ] || die "no manifest at $MANIFEST; run bin/gen-manifest.py"

  if [ -d "$WT/.git" ] || [ -f "$WT/.git" ]; then
    echo "$WT"
    return
  fi

  git -C "$REPO_ROOT" fetch origin "$BRANCH" 2>/dev/null || true

  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git -C "$REPO_ROOT" worktree add "$WT" "$BRANCH" >&2
  elif git -C "$REPO_ROOT" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
    git -C "$REPO_ROOT" worktree add "$WT" -b "$BRANCH" "origin/$BRANCH" >&2
  else
    mkdir -p "$WT"
    git -C "$REPO_ROOT" worktree add --detach "$WT" >&2
    git -C "$WT" checkout --orphan "$BRANCH" >&2
    git -C "$WT" rm -rf . >/dev/null 2>&1 || true
    mkdir -p "$WT/ledger" "$WT/statements" "$WT/runs"
    cat > "$WT/README.md" <<'EOF'
# spec-audit ledger

Generated state for the AMQP 1.0 conformance audit. Do not edit by hand.

- `ledger/<id>.json` - one audit record for each specification unit.
- `statements/<id>.json` - cached normative statements extracted from the spec.
- `tree.json` - issue numbers for the root, part, and section tracking issues.
- `STATUS.md` - generated rollup.

The work-list lives on `main` in `docs/spec-audit/manifest.json`. This branch
is an orphan so `main` stays clean for a rebase onto upstream.
EOF
    touch "$WT/ledger/.keep" "$WT/statements/.keep" "$WT/runs/.keep"
    git -C "$WT" add -A >&2
    git -C "$WT" commit -m "chore(spec-audit): initialize ledger branch" >&2
    if [ "${SPEC_AUDIT_NO_PUSH:-0}" = "1" ]; then
      echo "ledger: SPEC_AUDIT_NO_PUSH=1, branch is local only" >&2
    else
      git -C "$WT" push -u origin "$BRANCH" >&2 || echo "ledger: push failed; branch is local only" >&2
    fi
  fi
  echo "$WT"
}

require_wt() { [ -d "$WT/ledger" ] || die "ledger not initialized; run: $0 init"; }

cmd_path() { require_wt; echo "$WT"; }

cmd_sync() {
  require_wt
  git -C "$WT" pull --rebase origin "$BRANCH" >&2 2>/dev/null || true
}

# --- records ----------------------------------------------------------------

cmd_get() {
  require_wt
  local id="${1:?usage: get <id>}"
  [ -f "$WT/ledger/$id.json" ] && cat "$WT/ledger/$id.json" || true
}

# put <id>  -- record JSON arrives on stdin
cmd_put() {
  require_wt
  local id="${1:?usage: put <id> < record.json}"
  local tmp; tmp="$(mktemp)"
  cat > "$tmp"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp" \
    || die "record for $id is not valid JSON"
  mv "$tmp" "$WT/ledger/$id.json"
  commit_and_push "ledger/$id.json" "chore(spec-audit): record $id"
}

cmd_statements() {
  require_wt
  local action="${1:?usage: statements get|put <id>}"; shift
  local id="${1:?usage: statements get|put <id>}"
  case "$action" in
    get) [ -f "$WT/statements/$id.json" ] && cat "$WT/statements/$id.json" || true ;;
    put)
      local tmp; tmp="$(mktemp)"; cat > "$tmp"
      python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp" \
        || die "statements for $id are not valid JSON"
      mv "$tmp" "$WT/statements/$id.json"
      commit_and_push "statements/$id.json" "chore(spec-audit): statements $id"
      ;;
    *) die "unknown statements action: $action" ;;
  esac
}

cmd_tree() {
  require_wt
  case "${1:-get}" in
    get) [ -f "$WT/tree.json" ] && cat "$WT/tree.json" || echo '{}' ;;
    put)
      local tmp; tmp="$(mktemp)"; cat > "$tmp"
      python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$tmp" \
        || die "tree.json is not valid JSON"
      mv "$tmp" "$WT/tree.json"
      commit_and_push "tree.json" "chore(spec-audit): update issue tree map"
      ;;
    *) die "unknown tree action: $1" ;;
  esac
}

# A push races another run, so rebase and try again. Never force.
commit_and_push() {
  local path="$1" msg="$2"
  git -C "$WT" add -- "$path"
  git -C "$WT" diff --cached --quiet && return 0
  git -C "$WT" commit -q -m "$msg"
  [ "${SPEC_AUDIT_NO_PUSH:-0}" = "1" ] && return 0
  local i
  for i in 1 2 3; do
    if git -C "$WT" push -q origin "$BRANCH" 2>/dev/null; then return 0; fi
    git -C "$WT" pull --rebase -q origin "$BRANCH" 2>/dev/null || true
  done
  echo "ledger: push failed after 3 tries; commit is local" >&2
}

cmd_push() {
  require_wt
  local i
  for i in 1 2 3; do
    if git -C "$WT" push -q origin "$BRANCH" 2>/dev/null; then return 0; fi
    git -C "$WT" pull --rebase -q origin "$BRANCH" 2>/dev/null || true
  done
  die "push failed after 3 tries"
}

# --- work-list --------------------------------------------------------------

# next [--part N] [--section S] [--count K] [--recheck] [--all]
cmd_next() {
  require_wt
  local head; head="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  python3 - "$MANIFEST" "$WT/ledger" "$head" "$@" <<'PY'
import json, os, sys

manifest, ledger_dir, head = sys.argv[1], sys.argv[2], sys.argv[3]
args = sys.argv[4:]

part = section = None
count = 1
recheck = show_all = False
i = 0
while i < len(args):
    a = args[i]
    if a == "--part": part = args[i + 1]; i += 2
    elif a == "--section": section = args[i + 1]; i += 2
    elif a == "--count": count = int(args[i + 1]); i += 2
    elif a == "--recheck": recheck = True; i += 1
    elif a == "--all": show_all = True; i += 1
    else: sys.exit("next: unknown flag %s" % a)

units = json.load(open(manifest))["units"]
out = []
for u in units:
    if part and str(u["part"]) != str(part) and u["part_slug"] != part:
        continue
    if section and not (u["id"] == section or u["id"].startswith(section + ".")):
        continue
    path = os.path.join(ledger_dir, u["id"] + ".json")
    if os.path.exists(path):
        rec = json.load(open(path))
        if not recheck:
            continue
        # --recheck re-audits only what the code has moved underneath.
        if rec.get("code_sha") == head:
            continue
    out.append("%s\t%s\t%s\t%s" % (
        u["id"], u["part_slug"], u["title"],
        "informative" if not u["normative"] else ",".join(u["surfaces"][:3]),
    ))

if not show_all:
    out = out[:count]
print("\n".join(out))
PY
}

cmd_show() {
  local id="${1:?usage: show <id>}"
  python3 - "$MANIFEST" "$id" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for u in m["units"]:
    if u["id"] == sys.argv[2]:
        print(json.dumps(u, indent=2)); break
else:
    sys.exit("show: no unit %s in the manifest" % sys.argv[2])
PY
}

cmd_status() {
  require_wt
  local head; head="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  python3 - "$MANIFEST" "$WT" "$head" <<'PY'
import json, os, sys
manifest, wt, head = sys.argv[1], sys.argv[2], sys.argv[3]
units = json.load(open(manifest))["units"]

recs = {}
for u in units:
    p = os.path.join(wt, "ledger", u["id"] + ".json")
    if os.path.exists(p):
        recs[u["id"]] = json.load(open(p))

order = ["violations-filed", "conformant", "not-applicable", "blocked"]
parts = {}
for u in units:
    d = parts.setdefault(u["part_slug"], {"total": 0, "done": 0, "findings": 0})
    d["total"] += 1
    r = recs.get(u["id"])
    if r:
        d["done"] += 1
        d["findings"] += len(r.get("findings", []))

lines = ["# AMQP 1.0 conformance audit status", ""]
lines.append("Code at `%s`. %d of %d units audited." % (head, len(recs), len(units)))
lines.append("")
lines.append("| Part | Audited | Total | Findings |")
lines.append("|---|---:|---:|---:|")
for slug in ["types", "transport", "messaging", "transactions", "security"]:
    d = parts.get(slug)
    if d:
        lines.append("| %s | %d | %d | %d |" % (slug, d["done"], d["total"], d["findings"]))
tot_f = sum(d["findings"] for d in parts.values())
lines.append("| **all** | **%d** | **%d** | **%d** |" % (len(recs), len(units), tot_f))
lines.append("")

by_status = {}
for r in recs.values():
    by_status.setdefault(r.get("status", "unknown"), []).append(r)
lines.append("## Verdicts")
lines.append("")
for s in order + sorted(set(by_status) - set(order)):
    if s in by_status:
        lines.append("- `%s`: %d" % (s, len(by_status[s])))
lines.append("")

stale = [i for i, r in recs.items() if not r.get("code_sha", "").startswith(head)]
if stale:
    lines.append("## Stale")
    lines.append("")
    lines.append("Audited against an older commit. Re-audit with `--recheck`.")
    lines.append("")
    lines.append("`%s`" % "` `".join(sorted(stale)))
    lines.append("")

lines.append("## Open findings")
lines.append("")
rows = []
for u in units:
    r = recs.get(u["id"])
    if r:
        for f in r.get("findings", []):
            rows.append("| %s | #%s | %s | %s |" % (
                u["id"], f.get("issue", "?"), f.get("severity", "?"), f.get("title", "")))
if rows:
    lines.append("| Section | Issue | Severity | Title |")
    lines.append("|---|---|---|---|")
    lines.extend(rows)
else:
    lines.append("None recorded.")
lines.append("")

open(os.path.join(wt, "STATUS.md"), "w").write("\n".join(lines) + "\n")
sys.stderr.write("audited %d/%d  findings %d  stale %d\n"
                 % (len(recs), len(units), tot_f, len(stale)))
print("\n".join(lines[:14]))
PY
  commit_and_push "STATUS.md" "chore(spec-audit): refresh status"
}

case "${1:-}" in
  init)       shift; cmd_init "$@" ;;
  path)       shift; cmd_path "$@" ;;
  sync)       shift; cmd_sync "$@" ;;
  next)       shift; cmd_next "$@" ;;
  show)       shift; cmd_show "$@" ;;
  get)        shift; cmd_get "$@" ;;
  put)        shift; cmd_put "$@" ;;
  statements) shift; cmd_statements "$@" ;;
  tree)       shift; cmd_tree "$@" ;;
  status)     shift; cmd_status "$@" ;;
  push)       shift; cmd_push "$@" ;;
  *) cat >&2 <<'EOF'
usage: ledger.sh <command>

  init                       create or attach the spec-audit ledger worktree
  path                       print the ledger worktree path
  sync                       rebase the ledger on origin
  next [--part N] [--section S] [--count K] [--recheck] [--all]
                             print the next unaudited units, tab separated:
                             id, part, title, surface hints
  show <id>                  print the manifest entry for one unit
  get <id>                   print the audit record for one unit
  put <id> < record.json     write, commit, and push one audit record
  statements get|put <id>    read or write the cached normative statements
  tree get|put               read or write the issue-tree number map
  status                     regenerate STATUS.md and print the rollup
  push                       push pending ledger commits

  SPEC_AUDIT_NO_PUSH=1 batches pushes; call `push` at the end of the run.
EOF
    exit 2 ;;
esac
