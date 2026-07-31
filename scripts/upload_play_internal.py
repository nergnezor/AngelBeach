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

import httplib2
from google.oauth2 import service_account
from google_auth_httplib2 import AuthorizedHttp
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload

SCOPES = ["https://www.googleapis.com/auth/androidpublisher"]
# The .aab is ~200MB; a single non-resumable request left the client
# blocking on the server's response past its read timeout. Resumable
# (chunked) upload avoids one giant request, and a longer client timeout
# gives slow chunks room to complete instead of raising TimeoutError.
CHUNK_SIZE = 8 * 1024 * 1024
HTTP_TIMEOUT_SECONDS = 300


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
    authed_http = AuthorizedHttp(creds, http=httplib2.Http(timeout=HTTP_TIMEOUT_SECONDS))
    service = build("androidpublisher", "v3", http=authed_http)

    edit = service.edits().insert(body={}, packageName=args.package).execute()
    edit_id = edit["id"]
    print(f"Opened edit {edit_id} for {args.package}")

    try:
        # mimetypes.guess_type() doesn't know the .aab extension, so an
        # explicit mimetype is required either way. resumable=True chunks
        # the ~200MB upload instead of sending it as one request.
        media = MediaFileUpload(
            args.aab,
            mimetype="application/octet-stream",
            chunksize=CHUNK_SIZE,
            resumable=True,
        )
        request = service.edits().bundles().upload(
            editId=edit_id,
            packageName=args.package,
            media_body=media,
        )
        upload = None
        while upload is None:
            status, upload = request.next_chunk(num_retries=3)
            if status:
                print(f"Uploaded {int(status.progress() * 100)}%")
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
