#!/usr/bin/env python3
"""One-off engine patch: stop generating the OBB downloader's Android
manifest <activity> entry when bPackageDataInsideApk is true, so
Play Console's "Play Billing Library AIDL version" pre-launch check
stops flagging it.

This project always sets bPackageDataInsideApk=True (data lives inside
the APK/AAB, no expansion file is ever downloaded). GenerateManifest()
in UEDeployAndroid.cs adds <activity android:name=".DownloaderActivity">
to AndroidManifest.xml unconditionally. This patch guards just that.

REVERTED AND REMOVED: an earlier version of this script also gated the
WriteJavaDownloadSupportFiles(...) call (which generates the Java
"Shim" support files) behind the same condition. That broke
compilation: GameActivity.java unconditionally
`import com.epicgames.unreal.DownloadShim;` regardless of packaging
mode, so skipping the Shim's generation is a hard compile error
("cannot find symbol class DownloadShim"), not just dead code. The
manifest-only patch below does not have this problem — nothing else
depends on the <activity> entry's *presence in the manifest* at
compile time, only OBBDownloaderService/DownloaderActivity's *class
files existing*, which this patch doesn't touch.

Net effect confirmed via classes.dex diff: this patch alone removes
DownloaderActivity from the compiled output, but OBBDownloaderService
and its Base64/licensing dependency chain remain (forced in at compile
time by the Shim, which the engine always needs). Whether that's
enough to satisfy Play Console's specific check has NOT been verified
against a real Play Console upload — only inferred from static
analysis. Test with an actual upload before assuming it's sufficient.

Content-anchored, not line-number based, and idempotent (safe to
re-run — skipped if the marker is already present). Fails loudly
instead of guessing if the engine source doesn't look like what's
expected — this edits a private engine fork, not the project, so a
silent wrong edit would be expensive.
"""
import sys

MARKER_MANIFEST = "// AngelBeach: gate OBB downloader manifest entry behind bPackageDataInsideApk"


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


def main():
    if len(sys.argv) != 2:
        print("usage: patch_engine_obb_downloader.py <path to UEDeployAndroid.cs>", file=sys.stderr)
        sys.exit(2)
    path = sys.argv[1]

    with open(path, encoding="utf-8") as f:
        lines = f.readlines()

    braces_before = sum(l.count("{") - l.count("}") for l in lines)
    parens_before = sum(l.count("(") - l.count(")") for l in lines)

    lines, changed = patch_manifest_activity(lines)

    if not changed:
        print("Nothing to do — already applied.")
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
