#!/usr/bin/env python3
"""One-off engine patch: gate the OBB downloader's AndroidManifest.xml entry
(and everything it pulls in — Play licensing AIDL stubs, a legacy
com.android.vending.billing Base64 helper) behind bPackageDataInsideApk.

This project always sets bPackageDataInsideApk=True (data lives inside the
APK/AAB, no expansion file is ever downloaded), so the OBB downloader
Activity is 100% dead code — but UEDeployAndroid.cs declares it in the
manifest unconditionally, which keeps it (and its dependency chain)
reachable through R8 and trips Play Console's "Play Billing Library AIDL
version" pre-launch check.

Content-anchored and brace-matched rather than line-number based, and
idempotent (safe to re-run). Fails loudly instead of guessing if the
engine source doesn't look like what we expect — this edits a private
engine fork, not the project, so a silent wrong edit would be expensive.
"""
import sys

MARKER = "// AngelBeach: gate OBB downloader manifest entry behind bPackageDataInsideApk"


def main():
    if len(sys.argv) != 2:
        print("usage: patch_engine_obb_downloader.py <path to UEDeployAndroid.cs>", file=sys.stderr)
        sys.exit(2)
    path = sys.argv[1]

    with open(path, encoding="utf-8") as f:
        lines = f.readlines()

    if any(MARKER in l for l in lines):
        print("Already patched, skipping.")
        return

    start = next((i for i, l in enumerate(lines) if "// For OBB download support" in l), None)
    if start is None:
        print("ERROR: anchor comment '// For OBB download support' not found — "
              "engine source doesn't match what this patch expects. Aborting without changes.",
              file=sys.stderr)
        sys.exit(1)

    if_line = start + 1
    if "if (bShowLaunchImage)" not in lines[if_line]:
        print(f"ERROR: expected 'if (bShowLaunchImage)' right after the anchor comment "
              f"(line {if_line + 1}), found: {lines[if_line]!r}. Aborting without changes.",
              file=sys.stderr)
        sys.exit(1)

    open_idx = if_line + 1
    if lines[open_idx].strip() != "{":
        print(f"ERROR: expected '{{' at line {open_idx + 1}, found: {lines[open_idx]!r}. "
              "Aborting without changes.", file=sys.stderr)
        sys.exit(1)

    depth = 0
    end = None
    for i in range(open_idx, len(lines)):
        depth += lines[i].count("{") - lines[i].count("}")
        if depth == 0 and i > open_idx:
            end = i
            break
    if end is None:
        print("ERROR: brace matching for the if-block never closed. Aborting without changes.",
              file=sys.stderr)
        sys.exit(1)

    # Fold in the else branch too, if present, so both ways of declaring the
    # activity (with/without launch-image attributes) are covered.
    j = end + 1
    if j < len(lines) and lines[j].strip() == "else":
        open_idx2 = j + 1
        if lines[open_idx2].strip() != "{":
            print(f"ERROR: expected '{{' after else at line {open_idx2 + 1}, found: "
                  f"{lines[open_idx2]!r}. Aborting without changes.", file=sys.stderr)
            sys.exit(1)
        depth = 0
        for i in range(open_idx2, len(lines)):
            depth += lines[i].count("{") - lines[i].count("}")
            if depth == 0 and i > open_idx2:
                end = i
                break

    braces_before = sum(l.count("{") - l.count("}") for l in lines)

    indent = lines[if_line][: len(lines[if_line]) - len(lines[if_line].lstrip("\t"))]
    guard_open = f"{indent}{MARKER}\n{indent}if (!bPackageDataInsideApk)\n{indent}{{\n"
    guard_close = f"{indent}}}\n"

    new_lines = lines[:if_line] + [guard_open] + lines[if_line : end + 1] + [guard_close] + lines[end + 1 :]

    braces_after = sum(l.count("{") - l.count("}") for l in new_lines)
    if braces_after != braces_before:
        print(f"ERROR: brace balance changed unexpectedly ({braces_before} -> {braces_after}). "
              "Not writing the file.", file=sys.stderr)
        sys.exit(1)

    with open(path, "w", encoding="utf-8") as f:
        f.writelines(new_lines)
    print(f"Patched: wrapped lines {if_line + 1}-{end + 1} of {path} in a bPackageDataInsideApk guard.")


if __name__ == "__main__":
    main()
