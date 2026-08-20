#!/usr/bin/env python3
"""Generate docs/spec-audit/manifest.json from the OASIS AMQP 1.0 specification.

The manifest is the fixed work-list for the spec-audit pipeline. One entry for
each leaf section of the specification. Never edit the manifest by hand; edit
this script and run it again.

Code-surface hints live in surfaces.json and are merged in by id prefix, so a
regeneration does not lose them.
"""

import json
import os
import re
import sys
import urllib.request

BASE = "https://docs.oasis-open.org/amqp/core/v1.0/os/"

PARTS = [
    (1, "types", "Types", "amqp-core-types-v1.0-os.html"),
    (2, "transport", "Transport", "amqp-core-transport-v1.0-os.html"),
    (3, "messaging", "Messaging", "amqp-core-messaging-v1.0-os.html"),
    (4, "transactions", "Transactions", "amqp-core-transactions-v1.0-os.html"),
    (5, "security", "Security", "amqp-core-security-v1.0-os.html"),
]

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.dirname(HERE)
CACHE_DIR = os.path.join(HERE, ".cache")

# A leaf whose id is listed here is informative prose. The audit closes it as
# not-applicable without an investigation pass. Keep this list short and argue
# for each entry, because a wrong entry silently drops coverage.
INFORMATIVE = {
    "1.3", "1.3.1", "1.3.2", "1.3.3", "1.3.4", "1.3.5",  # type notation only
    "2.1.1",   # conceptual model
    "3.1",     # messaging introduction
}

ROW = re.compile(
    r"<tr><td>\s*([0-9]+(?:\.[0-9]+)+)\s*"
    r'<a href="#([^"]+)">(.*?)</a>\s*</td></tr>',
    re.S,
)
TAGS = re.compile(r"<[^>]+>")


def fetch(filename):
    os.makedirs(CACHE_DIR, exist_ok=True)
    path = os.path.join(CACHE_DIR, filename)
    if not os.path.exists(path):
        sys.stderr.write("fetch %s\n" % filename)
        with urllib.request.urlopen(BASE + filename) as r:
            data = r.read()
        with open(path, "wb") as f:
            f.write(data)
    with open(path, "rb") as f:
        return f.read().decode("utf-8", "replace")


def toc_rows(html):
    start = html.find('<table class="toc"')
    if start < 0:
        raise SystemExit("no toc table found")
    end = html.find("</table>", start)
    for num, anchor, title in ROW.findall(html[start:end]):
        title = TAGS.sub("", title)
        title = re.sub(r"\s+", " ", title).strip()
        yield num, anchor, title


def kind_of(anchor):
    if anchor.startswith("type-"):
        return "type"
    if anchor.startswith("definition-"):
        return "constants"
    if anchor.startswith("section-"):
        return "section"
    return "prose"


def build():
    rows = []
    for part_no, slug, part_title, filename in PARTS:
        html = fetch(filename)
        for num, anchor, title in toc_rows(html):
            rows.append(
                {
                    "id": num,
                    "part": part_no,
                    "part_slug": slug,
                    "part_title": part_title,
                    "title": title,
                    "anchor": anchor,
                    "url": BASE + filename + "#" + anchor,
                    "kind": kind_of(anchor),
                }
            )

    ids = {r["id"] for r in rows}
    leaves = []
    for r in rows:
        # A row is a leaf when no other row extends its number by one level.
        if not any(i.startswith(r["id"] + ".") for i in ids):
            leaves.append(r)

    by_id = {r["id"]: r for r in rows}
    for r in leaves:
        parent = r["id"].rsplit(".", 1)[0]
        r["section"] = parent if parent in by_id else r["id"]
        r["section_title"] = by_id.get(r["section"], r)["title"]
        r["normative"] = r["id"] not in INFORMATIVE and r["section"] not in INFORMATIVE

    surfaces_path = os.path.join(OUT_DIR, "surfaces.json")
    surfaces = {}
    if os.path.exists(surfaces_path):
        with open(surfaces_path) as f:
            surfaces = json.load(f)
    for r in leaves:
        # Longest matching prefix wins: 2.6.7 beats 2.6 beats 2.
        best = ""
        for key in surfaces:
            if (r["id"] == key or r["id"].startswith(key + ".")) and len(key) > len(best):
                best = key
        r["surfaces"] = surfaces.get(best, [])

    return leaves


def main():
    leaves = build()
    manifest = {
        "spec": "OASIS AMQP Version 1.0, OASIS Standard, 29 October 2012",
        "base_url": BASE,
        "generated_by": "docs/spec-audit/bin/gen-manifest.py",
        "unit_count": len(leaves),
        "units": leaves,
    }
    out = os.path.join(OUT_DIR, "manifest.json")
    with open(out, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    counts = {}
    for r in leaves:
        counts[r["part_slug"]] = counts.get(r["part_slug"], 0) + 1
    sys.stderr.write("wrote %s: %d units %s\n" % (out, len(leaves), counts))
    sys.stderr.write("normative: %d  informative: %d\n" % (
        sum(1 for r in leaves if r["normative"]),
        sum(1 for r in leaves if not r["normative"]),
    ))


if __name__ == "__main__":
    main()
