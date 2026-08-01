#!/usr/bin/env python3
"""Upload an .aab to the Google Play internal testing track.

Usage:
  python3 upload_play_internal.py \
      --package com.angelbeach.beachvolleyball \
      --aab path/to/app.aab \
      --service-account-json path/to/key.json \
      [--track internal] [--release-notes "text" | --release-notes-file notes.txt]

Requires: pip install google-api-python-client google-auth

This intentionally avoids fastlane/Docker so it runs on any self-hosted
runner that just has python3 + pip — no extra runner setup needed.

Note: the Google Play Android Developer API cannot create a brand-new app
listing. Before the first CI upload, create the app in Play Console and
upload one build to the Internal testing track by hand — after that, every
subsequent upload (including versionCode bumps) can go through this script.
"""
import argparse
import sys

from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload

SCOPES = ["https://www.googleapis.com/auth/androidpublisher"]

# Play rejects release notes longer than this (per language).
MAX_RELEASE_NOTES = 500


def load_release_notes(args):
    """Release notes text, from --release-notes-file or --release-notes.

    Truncated on a line boundary where possible so the text never ends
    mid-sentence, since Play rejects anything over MAX_RELEASE_NOTES.
    """
    if args.release_notes_file:
        with open(args.release_notes_file, encoding="utf-8") as f:
            text = f.read()
    else:
        text = args.release_notes

    text = text.strip()
    if len(text) <= MAX_RELEASE_NOTES:
        return text

    kept = []
    used = 0
    for line in text.splitlines():
        # +1 for the newline that rejoins this line to the previous one.
        cost = len(line) + (1 if kept else 0)
        if used + cost > MAX_RELEASE_NOTES - 2:
            break
        kept.append(line)
        used += cost

    if kept:
        return "\n".join(kept) + "\n…"
    return text[: MAX_RELEASE_NOTES - 1].rstrip() + "…"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--package", required=True)
    p.add_argument("--aab", required=True)
    p.add_argument("--service-account-json", required=True)
    p.add_argument("--track", default="internal")
    p.add_argument("--release-notes", default="")
    p.add_argument("--release-notes-file", default="",
                   help="Read release notes from this file instead (multi-line friendly).")
    args = p.parse_args()

    creds = service_account.Credentials.from_service_account_file(
        args.service_account_json, scopes=SCOPES
    )
    service = build("androidpublisher", "v3", credentials=creds)

    edit = service.edits().insert(body={}, packageName=args.package).execute()
    edit_id = edit["id"]
    print(f"Opened edit {edit_id} for {args.package}")

    try:
        upload = (
            service.edits()
            .bundles()
            .upload(
                editId=edit_id,
                packageName=args.package,
                # mimetypes.guess_type() doesn't know the .aab extension, and
                # media_body as a plain path string relies on that guess —
                # pass a MediaFileUpload with an explicit mimetype instead.
                media_body=MediaFileUpload(args.aab, mimetype="application/octet-stream"),
            )
            .execute()
        )
        version_code = upload["versionCode"]
        print(f"Uploaded bundle, versionCode={version_code}")

        release = {
            "versionCodes": [str(version_code)],
            "status": "completed",
        }
        notes = load_release_notes(args)
        if notes:
            release["releaseNotes"] = [{"language": "en-US", "text": notes}]
            print(f"Release notes ({len(notes)} chars):\n{notes}")

        service.edits().tracks().update(
            editId=edit_id,
            packageName=args.package,
            track=args.track,
            body={"releases": [release]},
        ).execute()
        print(f"Assigned versionCode={version_code} to track '{args.track}'")

        service.edits().commit(editId=edit_id, packageName=args.package).execute()
        print("Edit committed. Release is live on the track.")

    except Exception:
        print("ERROR during upload — deleting the open edit so it doesn't block the next run.", file=sys.stderr)
        try:
            service.edits().delete(editId=edit_id, packageName=args.package).execute()
        except Exception as cleanup_err:
            print(f"(also failed to clean up edit: {cleanup_err})", file=sys.stderr)
        raise


if __name__ == "__main__":
    main()
