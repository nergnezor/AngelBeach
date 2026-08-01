#!/usr/bin/env python3
"""Turn commit subjects into a categorised changelog for the Play release notes.

Reads one commit subject per line on stdin (newest first, e.g. from
`git log --no-merges --format='%s'`) and groups them by their Conventional
Commit type, so testers get

    Fixes
    • sand renders as sand instead of a checkerboard
    • the net is visible again

    Under the hood
    • ci: real commit subjects as release notes

instead of a flat list of raw subjects.

Anything without a recognisable `type(scope): ` prefix still shows up, under
"Other" — the changelog degrades rather than dropping commits on the floor.

Play caps release notes at 500 characters per language, so --max-chars trims
from the least important section upwards and never leaves a dangling header.
"""
import argparse
import re
import sys

# Section title -> the Conventional Commit types it collects, most important
# first. A commit marked breaking (`feat!:` / `fix(x)!:`) jumps to the top
# regardless of its type.
SECTIONS = [
    ("Breaking", ["!"]),
    ("New", ["feat"]),
    ("Fixes", ["fix"]),
    ("Performance", ["perf"]),
    ("Reverted", ["revert"]),
    ("Under the hood", ["build", "chore", "ci", "docs", "refactor", "style", "test"]),
    ("Other", [None]),
]

SUBJECT_RE = re.compile(
    r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]*)\))?(?P<breaking>!)?:\s*(?P<subject>.+)$"
)

# Types whose scope is worth keeping in the text: for plumbing changes "ci: ..."
# tells a reader why a line that isn't about gameplay is in the list at all.
SCOPE_WORTH_SHOWING = {"build", "chore", "ci", "docs", "refactor", "style", "test"}


def parse(line):
    """(section_title, bullet_text) for one commit subject."""
    line = line.strip()
    if not line:
        return None

    m = SUBJECT_RE.match(line)
    if not m:
        return "Other", line

    ctype = m.group("type")
    subject = m.group("subject").strip()

    if m.group("breaking"):
        title = "Breaking"
    else:
        title = next(
            (t for t, types in SECTIONS if ctype in types),
            "Other",
        )

    # Keep the type as a hint on plumbing lines, drop it everywhere else — under
    # a "Fixes" header, "fix: " on every bullet is pure noise.
    if ctype in SCOPE_WORTH_SHOWING:
        subject = f"{ctype}: {subject}"

    return title, subject


def _layout(grouped, budget):
    """(lines, dropped_count) for as much of `grouped` as fits in `budget`."""
    out = []
    used = 0
    dropped = 0
    for title, _ in SECTIONS:
        bullets = grouped.get(title)
        if not bullets:
            continue

        # A header only earns its characters if at least one bullet fits under it.
        block_sep = 2 if out else 0
        fitted = []
        cost = block_sep + len(title)
        for bullet in bullets:
            if used + cost + 1 + len(bullet) > budget:
                break
            fitted.append(bullet)
            cost += 1 + len(bullet)

        dropped += len(bullets) - len(fitted)
        if not fitted:
            continue
        if out:
            out.append("")
        out.append(title)
        out.extend(fitted)
        used += cost

    return out, dropped


def build(lines, max_chars, footer):
    grouped = {}
    total = 0
    for line in lines:
        parsed = parse(line)
        if parsed is None:
            continue
        title, text = parsed
        bullet = f"• {text}"
        # Same subject twice (a cherry-pick, a re-landed commit) reads as a bug.
        if bullet not in grouped.setdefault(title, []):
            grouped[title].append(bullet)
            total += 1

    budget = max_chars - (len(footer) + 2 if footer else 0)  # blank line + footer

    out, dropped = _layout(grouped, budget)
    if dropped:
        # Say so rather than silently swallowing commits. Reserve the widest the
        # trailer could ever get (dropped <= total), so the second pass can only
        # come in under budget, never over.
        reserve = len(f"…and {total} more") + 1
        out, dropped = _layout(grouped, budget - reserve)
        if dropped:
            out.append(f"…and {dropped} more")

    if not out:
        return footer

    text = "\n".join(out)
    if footer:
        text += f"\n\n{footer}"
    return text


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--max-chars", type=int, default=500,
                   help="Play's per-language limit (default: 500).")
    p.add_argument("--footer", default="",
                   help="Always-kept trailer, e.g. 'Build 42 (abc1234)'.")
    args = p.parse_args()

    print(build(sys.stdin.read().splitlines(), args.max_chars, args.footer))


if __name__ == "__main__":
    main()
