#!/usr/bin/env bash
# =============================================================================
# Angel Beach – self-hosted runner watchdog
#
# The GitHub Actions runner process can wedge without ever exiting: its
# broker connection drops (observed cause: a cancelled socket mid-poll), it
# logs "Back off N seconds before next retry" and keeps refreshing its OAuth
# token forever, but never resumes actually listening for jobs. systemd sees
# the process as healthy the whole time (`active`, PID unchanged), so its
# normal Restart= policy never fires — there is nothing for it to restart.
# This happened twice (2026-07-19, 2026-07-31), both times going unnoticed
# for hours until someone checked manually.
#
# This script is the external liveness check systemd can't provide on its
# own: a run sitting in "queued" for a while when GitHub itself reports the
# runner online and idle means the listener is wedged, not busy. Run it on
# a timer (see scripts/systemd/) and it restarts the service when that
# happens.
#
# Requires: gh CLI authenticated as a user who can read Actions runs/runners
# for REPO, and passwordless sudo for exactly the one restart command (see
# scripts/systemd/runner-watchdog.sudoers).
# =============================================================================
set -euo pipefail

REPO="${REPO:-nergnezor/AngelBeach}"
SERVICE="${SERVICE:-actions.runner.nergnezor-AngelBeach.erik-Nitro-N50-640.service}"
RUNNER_NAME="${RUNNER_NAME:-erik-Nitro-N50-640}"
# How long a run may sit queued before we treat the runner as wedged.
STALE_QUEUE_SECONDS="${STALE_QUEUE_SECONDS:-600}"
# Don't restart more than once in this window, in case restarting doesn't
# actually fix it (e.g. a real outage) — no point thrashing the service.
COOLDOWN_SECONDS="${COOLDOWN_SECONDS:-900}"
STATE_DIR="${STATE_DIR:-$HOME/actions-runner}"
LOG="$STATE_DIR/watchdog.log"
LAST_RESTART_FILE="$STATE_DIR/.watchdog-last-restart"

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%SZ')] $*" | tee -a "$LOG"; }

now_epoch=$(date -u +%s)

# Skip entirely if we already restarted recently — give it a chance to recover.
if [ -f "$LAST_RESTART_FILE" ]; then
  last_restart=$(cat "$LAST_RESTART_FILE")
  since=$(( now_epoch - last_restart ))
  if [ "$since" -lt "$COOLDOWN_SECONDS" ]; then
    log "Cooldown active (${since}s since last restart, < ${COOLDOWN_SECONDS}s) — skipping check."
    exit 0
  fi
fi

runner_json=$(gh api "repos/$REPO/actions/runners" --jq \
  ".runners[] | select(.name == \"$RUNNER_NAME\")")

if [ -z "$runner_json" ]; then
  log "WARN: runner '$RUNNER_NAME' not found in $REPO — nothing to check."
  exit 0
fi

status=$(echo "$runner_json" | jq -r '.status')
busy=$(echo "$runner_json" | jq -r '.busy')

if [ "$status" != "online" ] || [ "$busy" = "true" ]; then
  # Offline: a real outage, not what this watchdog handles (systemd's own
  # Restart= plus the "runner not running at all" case need a human anyway).
  # Busy: legitimately working — a second job queued behind it is expected.
  exit 0
fi

oldest_queued_age=0
oldest_queued_name=""
while IFS=$'\t' read -r created_at name; do
  [ -z "$created_at" ] && continue
  created_epoch=$(date -u -d "$created_at" +%s 2>/dev/null || echo "$now_epoch")
  age=$(( now_epoch - created_epoch ))
  if [ "$age" -gt "$oldest_queued_age" ]; then
    oldest_queued_age=$age
    oldest_queued_name=$name
  fi
done < <(gh run list --repo "$REPO" --status queued --limit 20 \
            --json createdAt,name -q '.[] | [.createdAt, .name] | @tsv')

if [ "$oldest_queued_age" -le "$STALE_QUEUE_SECONDS" ]; then
  exit 0
fi

log "STUCK: runner '$RUNNER_NAME' is online+idle but \"$oldest_queued_name\" has been queued ${oldest_queued_age}s (> ${STALE_QUEUE_SECONDS}s). Restarting $SERVICE."
sudo -n systemctl restart "$SERVICE"
echo "$now_epoch" > "$LAST_RESTART_FILE"
log "Restarted $SERVICE."
