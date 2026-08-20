#!/usr/bin/env bash
# Issue-tree helper for the AMQP 1.0 spec-audit pipeline.
#
# The tree uses native GitHub sub-issues, four levels deep:
#
#   root tracker
#     part tracker      (5, one for each specification part)
#       section tracker (created the first time a section produces a finding)
#         finding       (the leaf; this is what the fix pipeline works)
#
# GitHub allows 100 sub-issues under one parent and eight levels of nesting,
# so the shape has room. The sub-issue API takes the issue *database id*, not
# the issue number, which is the trap this script exists to hide.
#
# Usage: docs/spec-audit/bin/tree.sh <command> [args]
set -euo pipefail

REPO="${SPEC_AUDIT_REPO:-j7nw4r/fe2o3-amqp}"
UPSTREAM="${SPEC_AUDIT_UPSTREAM:-minghuaw/fe2o3-amqp}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
LEDGER="$REPO_ROOT/docs/spec-audit/bin/ledger.sh"
MANIFEST="$REPO_ROOT/docs/spec-audit/manifest.json"
WIP_CAP="${SPEC_AUDIT_WIP_CAP:-5}"

die() { echo "tree: $*" >&2; exit 1; }
gha() { gh api -H "Accept: application/vnd.github+json" "$@"; }

# tree.json is small. Read it, merge one key path, write it back.
tree_get() { "$LEDGER" tree get; }
tree_set() {  # tree_set <top-key> [<sub-key>] <value>
  "$LEDGER" tree get | python3 -c '
import json, sys
d = json.load(sys.stdin)
a = sys.argv[1:]
if len(a) == 2:
    d[a[0]] = a[1]
else:
    d.setdefault(a[0], {})[a[1]] = a[2]
print(json.dumps(d, indent=2))
' "$@" | "$LEDGER" tree put
}
tree_lookup() {  # tree_lookup <top-key> [<sub-key>]
  "$LEDGER" tree get | python3 -c '
import json, sys
d = json.load(sys.stdin)
a = sys.argv[1:]
v = d.get(a[0], {} if len(a) > 1 else "")
print((v.get(a[1], "") if len(a) > 1 else v) or "")
' "$@"
}

# Exact-title lookup so a rerun adopts what a previous run created.
find_issue_by_title() {
  gh issue list --repo "$REPO" --state all --limit 300 --label spec-audit \
    --json number,title 2>/dev/null \
  | python3 -c '
import json, sys
want = sys.argv[1]
for i in json.load(sys.stdin):
    if i["title"] == want:
        print(i["number"]); break
' "$1"
}

manifest_field() {  # manifest_field <unit-id> <field>
  python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
for u in m["units"]:
    if u["id"] == sys.argv[2]:
        print(u[sys.argv[3]]); break
else:
    sys.exit("tree: no unit %s in the manifest" % sys.argv[2])
' "$MANIFEST" "$1" "$2"
}

section_field() {  # section_field <section-id> <field>
  python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
for u in m["units"]:
    if u["section"] == sys.argv[2]:
        print(u[sys.argv[3]]); break
else:
    sys.exit("tree: no section %s in the manifest" % sys.argv[2])
' "$MANIFEST" "$1" "$2"
}

issue_id() { gha "repos/$REPO/issues/$1" --jq '.id'; }

# --- structure --------------------------------------------------------------

cmd_attach() {
  local parent="${1:?usage: attach <parent> <child>}" child="${2:?}"
  local cid; cid="$(issue_id "$child")"
  gha --method POST "repos/$REPO/issues/$parent/sub_issues" \
      -F "sub_issue_id=$cid" -F 'replace_parent=true' >/dev/null
  echo "tree: attached #$child under #$parent" >&2
}

cmd_children() {
  gha "repos/$REPO/issues/${1:?usage: children <parent>}/sub_issues" --paginate \
    --jq '.[] | "\(.number)\t\(.state)\t\(.title)"'
}

ensure_label() {
  gh label create "$1" --repo "$REPO" --color "$2" --description "$3" >/dev/null 2>&1 && return 0
  gh label edit   "$1" --repo "$REPO" --color "$2" --description "$3" >/dev/null 2>&1 || true
}

# create_issue <title> <body-file> <label>...  -> issue number
create_issue() {
  local title="$1" body="$2"; shift 2
  local args=(); local l
  for l in "$@"; do args+=(--label "$l"); done
  gh issue create --repo "$REPO" --title "$title" --body-file "$body" "${args[@]}" \
    | grep -oE '[0-9]+$'
}

cmd_bootstrap() {
  [ "$(gha "repos/$REPO" --jq '.has_issues')" = "true" ] || {
    echo "tree: issues are disabled on $REPO; enabling" >&2
    gh repo edit "$REPO" --enable-issues
  }

  ensure_label spec-audit             0e8a16 "AMQP 1.0 conformance audit"
  ensure_label spec-tracking          c5def5 "Tracking node in the tree, not a unit of work"
  ensure_label spec-part/types        1d76db "AMQP 1.0 Part 1: Types"
  ensure_label spec-part/transport    1d76db "AMQP 1.0 Part 2: Transport"
  ensure_label spec-part/messaging    1d76db "AMQP 1.0 Part 3: Messaging"
  ensure_label spec-part/transactions 1d76db "AMQP 1.0 Part 4: Transactions"
  ensure_label spec-part/security     1d76db "AMQP 1.0 Part 5: Security"
  ensure_label sev/must               b60205 "Violates a normative MUST or MUST NOT"
  ensure_label sev/mandatory-missing  d93f0b "A mandatory field, type, or behavior is absent"
  ensure_label spec-fix/in-progress   fbca04 "A fix run holds this issue"

  "$LEDGER" init >/dev/null
  local tmp; tmp="$(mktemp -d)"

  local root; root="$(tree_lookup root)"
  [ -z "$root" ] && root="$(find_issue_by_title "AMQP 1.0 conformance audit")"
  if [ -z "$root" ]; then
    cat > "$tmp/root.md" <<'EOF'
## Summary

This issue is the root of the AMQP 1.0 conformance tree. Each child covers one part of the OASIS AMQP Version 1.0 standard. Each grandchild covers one section, and each leaf states one conformance defect.

## Motivation

The codebase has no record of which parts of the specification it satisfies. An audit that walks the specification section by section produces that record and turns each gap into a unit of work.

## Proposal

- Audit all 164 leaf sections of the specification, one section at a time.
- File one issue for each normative MUST or MUST NOT violation, and for each absent mandatory feature.
- Record every verdict, a clean one included, on the `spec-audit` ledger branch.
- Track progress in `STATUS.md` on that branch.

Process: `docs/spec-audit/README.md`. Work-list: `docs/spec-audit/manifest.json`.
EOF
    root="$(create_issue "AMQP 1.0 conformance audit" "$tmp/root.md" spec-audit spec-tracking)"
    echo "tree: created root #$root" >&2
  fi
  tree_set root "$root"
  tree_set repo "$REPO"

  local spec p slug title num
  for spec in "1:types:Types" "2:transport:Transport" "3:messaging:Messaging" \
              "4:transactions:Transactions" "5:security:Security"; do
    IFS=: read -r p slug title <<< "$spec"
    num="$(tree_lookup parts "$slug")"
    [ -z "$num" ] && num="$(find_issue_by_title "Part $p: $title conformance")"
    if [ -z "$num" ]; then
      cat > "$tmp/part.md" <<EOF
## Summary

Conformance of the codebase with OASIS AMQP Version 1.0, Part $p: $title.

## Motivation

Each section of this part states normative requirements. A child issue appears here for each section that holds a defect.

## Proposal

Audit each section of Part $p. Attach one section tracker for each section that produces a finding. A section with no finding is recorded on the \`spec-audit\` branch and produces no issue.

Specification: https://docs.oasis-open.org/amqp/core/v1.0/os/amqp-core-$slug-v1.0-os.html
EOF
      num="$(create_issue "Part $p: $title conformance" "$tmp/part.md" \
             spec-audit spec-tracking "spec-part/$slug")"
      cmd_attach "$root" "$num"
      echo "tree: created part $slug #$num" >&2
    fi
    tree_set parts "$slug" "$num"
  done

  rm -rf "$tmp"
  echo "tree: bootstrap complete; root #$root" >&2
}

# section <section-id> -> tracker number, created once
cmd_section() {
  local sec="${1:?usage: section <section-id>}"
  local num; num="$(tree_lookup sections "$sec")"
  if [ -n "$num" ]; then echo "$num"; return; fi

  local sec_title part_slug part_title
  sec_title="$(section_field "$sec" section_title)"
  part_slug="$(section_field "$sec" part_slug)"
  part_title="$(section_field "$sec" part_title)"

  local title="[$sec] $sec_title"
  num="$(find_issue_by_title "$title")"
  if [ -z "$num" ]; then
    local tmp; tmp="$(mktemp -d)"
    cat > "$tmp/sec.md" <<EOF
## Summary

Conformance defects found in AMQP 1.0 section $sec, $sec_title.

## Motivation

Part $part_title, section $sec states normative requirements the codebase does not satisfy. Each child issue names one of them.

## Proposal

Fix each child issue. Close this tracker when every child is closed and the section re-audits clean with \`/spec-audit --section $sec --recheck\`.
EOF
    num="$(create_issue "$title" "$tmp/sec.md" spec-audit spec-tracking "spec-part/$part_slug")"
    rm -rf "$tmp"
    cmd_attach "$(tree_lookup parts "$part_slug")" "$num"
    echo "tree: created section tracker $sec #$num" >&2
  fi
  tree_set sections "$sec" "$num"
  echo "$num"
}

# --- findings ---------------------------------------------------------------

cmd_dupes() {
  local id="${1:?usage: dupes <unit-id> [keywords]}"; shift || true
  echo "== already filed against section $id ==" >&2
  gh issue list --repo "$REPO" --state all --limit 100 --label spec-audit \
    --search "[$id] in:title" --json number,state,title \
    --jq '.[] | "\(.number)\t\(.state)\t\(.title)"' 2>/dev/null || true
  if [ $# -gt 0 ]; then
    echo "== keyword matches across the tree ==" >&2
    gh issue list --repo "$REPO" --state all --limit 30 --label spec-audit \
      --search "$*" --json number,state,title \
      --jq '.[] | "\(.number)\t\(.state)\t\(.title)"' 2>/dev/null || true
    echo "== related issues upstream ($UPSTREAM) ==" >&2
    gh issue list --repo "$UPSTREAM" --state all --limit 15 \
      --search "$*" --json number,state,title \
      --jq '.[] | "\(.number)\t\(.state)\t\(.title)"' 2>/dev/null || true
  fi
}

# file <finding.json> -> issue number.  Schema: docs/spec-audit/README.md
cmd_file() {
  local f="${1:?usage: file <finding.json>}"
  [ -f "$f" ] || die "no such file: $f"
  local unit sec title sev part_slug tmp
  unit="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["unit"])' "$f")"
  title="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["title"])' "$f")"
  sev="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["severity"])' "$f")"
  case "$sev" in must|mandatory-missing) ;; *) die "severity must be must or mandatory-missing, got $sev" ;; esac
  sec="$(manifest_field "$unit" section)"
  part_slug="$(manifest_field "$unit" part_slug)"

  tmp="$(mktemp -d)"
  python3 -c 'import json,sys;sys.stdout.write(json.load(open(sys.argv[1]))["body"])' "$f" > "$tmp/body.md"

  local parent num
  parent="$(cmd_section "$sec")"
  num="$(create_issue "[$unit] $title" "$tmp/body.md" \
         spec-audit "spec-part/$part_slug" "sev/$sev")"
  rm -rf "$tmp"
  cmd_attach "$parent" "$num"
  echo "$num"
}

# --- fix-side queries -------------------------------------------------------

cmd_wip() {
  local n; n="$(gh pr list --repo "$REPO" --state open --json number --jq 'length')"
  echo "$n"
  if [ "$n" -ge "$WIP_CAP" ]; then
    echo "tree: $n open pull requests, cap is $WIP_CAP; merge or close one first" >&2
    gh pr list --repo "$REPO" --state open \
      --json number,title,isDraft,statusCheckRollup \
      --jq '.[] | "  #\(.number)\t\(if .isDraft then "draft" else "ready" end)\t\(.title)"' >&2
  fi
}

cmd_ready() {
  local count=10
  [ "${1:-}" = "--count" ] && count="${2:?}"
  gh issue list --repo "$REPO" --state open --limit 300 --label spec-audit \
    --json number,title,labels 2>/dev/null \
  | python3 -c '
import json, sys
count = int(sys.argv[1])
rows = []
for i in json.load(sys.stdin):
    names = [l["name"] for l in i["labels"]]
    if "spec-tracking" in names or "spec-fix/in-progress" in names:
        continue
    sev = next((n for n in names if n.startswith("sev/")), "sev/?")
    rows.append((0 if sev == "sev/mandatory-missing" else 1, i["number"], sev, i["title"]))
for _, n, sev, t in sorted(rows)[:count]:
    print("%s\t%s\t%s" % (n, sev, t))
' "$count"
}

cmd_claim()   { gh issue edit "${1:?usage: claim <n>}"   --repo "$REPO" --add-label    spec-fix/in-progress >/dev/null; }
cmd_release() { gh issue edit "${1:?usage: release <n>}" --repo "$REPO" --remove-label spec-fix/in-progress >/dev/null; }

case "${1:-}" in
  bootstrap) shift; cmd_bootstrap "$@" ;;
  section)   shift; cmd_section "$@" ;;
  dupes)     shift; cmd_dupes "$@" ;;
  file)      shift; cmd_file "$@" ;;
  attach)    shift; cmd_attach "$@" ;;
  children)  shift; cmd_children "$@" ;;
  ready)     shift; cmd_ready "$@" ;;
  wip)       shift; cmd_wip "$@" ;;
  claim)     shift; cmd_claim "$@" ;;
  release)   shift; cmd_release "$@" ;;
  *) cat >&2 <<'EOF'
usage: tree.sh <command>

  bootstrap                enable issues, create labels, create root and part trackers
  section <section-id>     print the section tracker number, creating it once
  dupes <unit-id> [kw...]  list issues that might already cover a finding
  file <finding.json>      create a finding issue and attach it to its section
  attach <parent> <child>  make one issue a sub-issue of another
  children <parent>        list the sub-issues of one issue
  ready [--count K]        list leaf issues no fix run holds
  wip                      print the count of open pull requests
  claim <n> | release <n>  take or drop the fix lock on one issue

  SPEC_AUDIT_REPO     repository to file against (default j7nw4r/fe2o3-amqp)
  SPEC_AUDIT_UPSTREAM repository to search for related work (default minghuaw/fe2o3-amqp)
  SPEC_AUDIT_WIP_CAP  open pull request cap (default 5)
EOF
    exit 2 ;;
esac
