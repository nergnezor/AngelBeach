#!/usr/bin/env python3
"""Upload an .aab to the Google Play internal testing track.

Usage:
  python3 upload_play_internal.py \
      --package com.angelbeach.beachvolleyball \
      --aab path/to/app.aab \
      --service-account-json path/to/key.json \
      [--track internal] [--release-notes "text"]

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

SCOPES = ["https://www.googleapis.com/auth/androidpublisher"]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--package", required=True)
    p.add_argument("--aab", required=True)
    p.add_argument("--service-account-json", required=True)
    p.add_argument("--track", default="internal")
    p.add_argument("--release-notes", default="")
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
                media_body=args.aab,
            )
            .execute()
        )
        version_code = upload["versionCode"]
        print(f"Uploaded bundle, versionCode={version_code}")

        release = {
            "versionCodes": [str(version_code)],
            "status": "completed",
        }
        if args.release_notes:
            release["releaseNotes"] = [
                {"language": "en-US", "text": args.release_notes}
            ]

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
