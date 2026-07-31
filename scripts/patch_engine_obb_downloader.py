#!/usr/bin/env python3
"""One-off engine patch: stop generating the OBB downloader's Android
manifest entry and Java "Shim" support files when bPackageDataInsideApk
is true, so Play Console's "Play Billing Library AIDL version" check
stops tripping on dead code.

This project always sets bPackageDataInsideApk=True (data lives inside
the APK/AAB, no expansion file is ever downloaded). Two separate places
in UEDeployAndroid.cs generate OBB-downloader-related content
unconditionally:

  1. GenerateManifest() adds <activity android:name=".DownloaderActivity">
     to AndroidManifest.xml no matter what.
  2. The packaging pipeline unconditionally calls
     WriteJavaDownloadSupportFiles(...), which writes a "Shim" class that
     imports OBBDownloaderService/DownloaderActivity directly — a plain
     Java import, so those classes have to exist and get compiled in
     regardless of the manifest.

Patch #1 alone removes the <activity> entry but DownloaderActivity is
still reachable through the Shim's import, so both must be gated.
Confirmed safe: the manifest already carries
com.epicgames.unreal.GameActivity.bPackageDataInsideApk and
.bVerifyOBBOnStartUp metadata specifically so the Java/native runtime
can skip this whole subsystem when set — this project sets both
bPackageDataInsideApk=True and bDisableVerifyOBBOnStartUp=True, so the
runtime already never engages this code path; removing the dead classes
from compilation shouldn't remove anything actually used.

Content-anchored, not line-number based, and idempotent (safe to
re-run — each patch has its own marker and is skipped if already
applied). Fails loudly instead of guessing if the engine source doesn't
look like what's expected — this edits a private engine fork, not the
project, so a silent wrong edit would be expensive.
"""
import sys

MARKER_MANIFEST = "// AngelBeach: gate OBB downloader manifest entry behind bPackageDataInsideApk"
MARKER_SHIM = "// AngelBeach: skip the OBB downloader Shim/support files behind bPackageDataInsideApk"


def brace_matched_end(lines, open_idx):
    """Given the index of a line that is exactly '{', return the index of
    the line holding its matching '}' (brace-depth based)."""
    depth = 0
    for i in range(open_idx, len(lines)):
        depth += lines[i].count("{") - lines[i].count("}")
        if depth == 0 and i > open_idx:
            return i
    return None


def patch_manifest_activity(lines):
    if any(MARKER_MANIFEST in l for l in lines):
        print("[manifest] Already patched, skipping.")
        return lines, False

    start = next((i for i, l in enumerate(lines) if "// For OBB download support" in l), None)
    if start is None:
        print("ERROR[manifest]: anchor comment '// For OBB download support' not found. "
              "Aborting without changes.", file=sys.stderr)
        sys.exit(1)

    if_line = start + 1
    if "if (bShowLaunchImage)" not in lines[if_line]:
        print(f"ERROR[manifest]: expected 'if (bShowLaunchImage)' right after the anchor "
              f"comment (line {if_line + 1}), found: {lines[if_line]!r}. Aborting.",
              file=sys.stderr)
        sys.exit(1)

    open_idx = if_line + 1
    if lines[open_idx].strip() != "{":
        print(f"ERROR[manifest]: expected '{{' at line {open_idx + 1}, found: "
              f"{lines[open_idx]!r}. Aborting.", file=sys.stderr)
        sys.exit(1)

    end = brace_matched_end(lines, open_idx)
    if end is None:
        print("ERROR[manifest]: brace matching for the if-block never closed. Aborting.",
              file=sys.stderr)
        sys.exit(1)

    j = end + 1
    if j < len(lines) and lines[j].strip() == "else":
        open_idx2 = j + 1
        if lines[open_idx2].strip() != "{":
            print(f"ERROR[manifest]: expected '{{' after else at line {open_idx2 + 1}, "
                  f"found: {lines[open_idx2]!r}. Aborting.", file=sys.stderr)
            sys.exit(1)
        end2 = brace_matched_end(lines, open_idx2)
        if end2 is None:
            print("ERROR[manifest]: brace matching for the else-block never closed. Aborting.",
                  file=sys.stderr)
            sys.exit(1)
        end = end2

    indent = lines[if_line][: len(lines[if_line]) - len(lines[if_line].lstrip("\t"))]
    guard_open = f"{indent}{MARKER_MANIFEST}\n{indent}if (!bPackageDataInsideApk)\n{indent}{{\n"
    guard_close = f"{indent}}}\n"

    new_lines = lines[:if_line] + [guard_open] + lines[if_line : end + 1] + [guard_close] + lines[end + 1 :]
    print(f"[manifest] Wrapped lines {if_line + 1}-{end + 1} in a bPackageDataInsideApk guard.")
    return new_lines, True


def patch_shim_call(lines):
    if any(MARKER_SHIM in l for l in lines):
        print("[shim] Already patched, skipping.")
        return lines, False

    anchor = "WriteJavaDownloadSupportFiles(UnrealDownloadShimFileName, templates,"
    start = next((i for i, l in enumerate(lines) if anchor in l), None)
    if start is None:
        print(f"ERROR[shim]: anchor call {anchor!r} not found. Aborting.", file=sys.stderr)
        sys.exit(1)

    # Find the end of the (possibly multi-line) call statement by tracking
    # parenthesis depth from the opening '(' on the anchor line — object
    # initializer braces inside the call don't affect paren depth.
    depth = 0
    end = None
    for i in range(start, len(lines)):
        depth += lines[i].count("(") - lines[i].count(")")
        if depth == 0 and i > start:
            end = i
            break
        if depth == 0 and i == start:
            # single-line call, shouldn't happen here given the anchor, but handle it
            end = i
            break
    if end is None:
        print("ERROR[shim]: paren matching for the call never closed. Aborting.", file=sys.stderr)
        sys.exit(1)
    if ";" not in lines[end]:
        print(f"ERROR[shim]: expected the call to end with ';' on line {end + 1}, "
              f"found: {lines[end]!r}. Aborting.", file=sys.stderr)
        sys.exit(1)

    indent = lines[start][: len(lines[start]) - len(lines[start].lstrip("\t"))]
    guard_open = f"{indent}{MARKER_SHIM}\n{indent}if (!bPackageDataInsideApk)\n{indent}{{\n"
    guard_close = f"{indent}}}\n"

    new_lines = lines[:start] + [guard_open] + lines[start : end + 1] + [guard_close] + lines[end + 1 :]
    print(f"[shim] Wrapped lines {start + 1}-{end + 1} in a bPackageDataInsideApk guard.")
    return new_lines, True


def main():
    if len(sys.argv) != 2:
        print("usage: patch_engine_obb_downloader.py <path to UEDeployAndroid.cs>", file=sys.stderr)
        sys.exit(2)
    path = sys.argv[1]

    with open(path, encoding="utf-8") as f:
        lines = f.readlines()

    braces_before = sum(l.count("{") - l.count("}") for l in lines)
    parens_before = sum(l.count("(") - l.count(")") for l in lines)

    lines, changed1 = patch_manifest_activity(lines)
    lines, changed2 = patch_shim_call(lines)

    if not (changed1 or changed2):
        print("Nothing to do — both patches already applied.")
        return

    braces_after = sum(l.count("{") - l.count("}") for l in lines)
    parens_after = sum(l.count("(") - l.count(")") for l in lines)
    if braces_after != braces_before or parens_after != parens_before:
        print(f"ERROR: balance changed unexpectedly (braces {braces_before}->{braces_after}, "
              f"parens {parens_before}->{parens_after}). Not writing the file.", file=sys.stderr)
        sys.exit(1)

    with open(path, "w", encoding="utf-8") as f:
        f.writelines(lines)
    print(f"Wrote {path}.")


if __name__ == "__main__":
    main()
