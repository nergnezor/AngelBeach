#!/usr/bin/env python3
"""Clear VSCode's stored task/debug state for this workspace.

VSCode caches task definitions per workspace in workspaceStorage/<hash>/state.vscdb,
separately from .vscode/tasks.json. When a task definition changes shape — notably a
background task losing `isBackground` — the stored copy can keep describing the old one.
A restored background task that can never signal readiness makes VSCode take its one
silent abort path when a debug config uses it as a preLaunchTask:

    let t = await this.runTask(root, taskId, token);
    if (t && (t.exitCode === undefined || t.cancelled)) return 0;   // no dialog, no output

so F5 does nothing at all: no terminal, no error, no Problems panel.

This removes the stored entries so VSCode rebuilds them from tasks.json. It is safe to
re-run, and it refuses to touch the database while VSCode still holds it open, because
VSCode keeps storage in memory and flushes on exit — writing underneath a running
instance gets silently overwritten at best.

Usage:  close VSCode completely, then:  python3 scripts/clear_vscode_task_state.py
"""
import json
import os
import shutil
import sqlite3
import sys
import time
from pathlib import Path

KEYS = [
    "workbench.tasks.persistentTasks",
    "workbench.tasks.recentlyUsedTasks2",
    "debug.taskerrorchoice",
]

PROJECT = Path(__file__).resolve().parent.parent


def find_storage(project: Path):
    """Locate every workspaceStorage entry pointing at this project folder."""
    found = []
    for root in (
        Path.home() / ".config/Code/User/workspaceStorage",
        Path.home() / ".config/Code - Insiders/User/workspaceStorage",
        Path.home() / ".vscode-server/data/User/workspaceStorage",
    ):
        if not root.is_dir():
            continue
        for entry in root.iterdir():
            meta = entry / "workspace.json"
            if not meta.is_file():
                continue
            try:
                folder = json.loads(meta.read_text()).get("folder", "")
            except (json.JSONDecodeError, OSError):
                continue
            if folder == project.as_uri() and (entry / "state.vscdb").is_file():
                found.append(entry / "state.vscdb")
    return found


def holders(db: Path):
    """PIDs with this database open — VSCode must be closed before we touch it."""
    pids = []
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            for fd in (proc / "fd").iterdir():
                if os.readlink(fd) == str(db):
                    pids.append(proc.name)
                    break
        except (PermissionError, FileNotFoundError, OSError):
            continue
    return pids


def main():
    dbs = find_storage(PROJECT)
    if not dbs:
        print(f"No VSCode workspace storage found for {PROJECT}. Nothing to do.")
        return 0

    for db in dbs:
        print(f"\n{db}")
        busy = holders(db)
        if busy:
            print(f"  SKIPPED: still open by PID {', '.join(busy)} — close VSCode first.")
            return 1

        backup = db.with_suffix(f".vscdb.bak-{time.strftime('%Y%m%d-%H%M%S')}")
        shutil.copy2(db, backup)
        print(f"  backup: {backup.name}")

        con = sqlite3.connect(db)
        try:
            removed = 0
            for key in KEYS:
                row = con.execute(
                    "select value from ItemTable where key = ?", (key,)
                ).fetchone()
                if row is None:
                    print(f"  - {key}: not present")
                    continue
                con.execute("delete from ItemTable where key = ?", (key,))
                removed += 1
                print(f"  - {key}: REMOVED ({len(row[0])} bytes)")
            con.commit()
        finally:
            con.close()
        print(f"  {removed} key(s) removed. Reopen VSCode; tasks come from tasks.json again.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
