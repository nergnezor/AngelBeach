#!/usr/bin/env bash
# Start the Unreal editor (or the game) and block until the Angelscript debug server is
# accepting connections, then exit.
#
# This exists to be a VSCode `preLaunchTask`. The obvious way to write that task —
# run the editor directly with "isBackground": true — does not work: a background task
# has to tell VSCode when it is ready via a problem matcher's `background.endsPattern`,
# a matcher VSCode rejects outright unless its pattern declares file/line/message groups,
# and a rejected matcher silently takes the background tracking with it. The debug session
# then waits forever for a task that never reports ready, so F5 appears to do nothing.
#
# So instead: launch detached, poll the port, exit 0. An ordinary task VSCode can just
# wait on, and one that can be run and verified straight from a shell.
#
#   ./scripts/launch_ue.sh editor      full editor
#   ./scripts/launch_ue.sh game        standalone game, no editor UI
#   EXTRA_ARGS="-RenderOffscreen -nosplash -unattended" ./scripts/launch_ue.sh game
set -uo pipefail

MODE="${1:-editor}"
PORT="${AS_DEBUG_PORT:-27099}"
TIMEOUT="${LAUNCH_TIMEOUT:-420}"
MAP="${MAP:-/Game/CourtLevel}"

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPROJECT="$PROJECT_DIR/BeachVolleyball.uproject"
UE_EDITOR="${ENGINE_DIR:-$HOME/UnrealEngine-Angelscript}/Engine/Binaries/Linux/UnrealEditor"
LOG="$PROJECT_DIR/Saved/Logs/launch-$MODE.log"

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; }

case "$MODE" in
	editor) ARGS=( "$UPROJECT" ) ;;
	game)   ARGS=( "$UPROJECT" "$MAP" -game ) ;;
	*) echo "usage: $0 [editor|game]" >&2; exit 2 ;;
esac
# shellcheck disable=SC2206  # deliberate word splitting: EXTRA_ARGS is a list of flags
[ -n "${EXTRA_ARGS:-}" ] && ARGS+=( ${EXTRA_ARGS} )

[ -x "$UE_EDITOR" ] || { echo "ERROR: engine not built at $UE_EDITOR (run 'make engine')" >&2; exit 1; }
[ -f "$UPROJECT" ]  || { echo "ERROR: project not found: $UPROJECT" >&2; exit 1; }

# Already running? Attach to that one rather than starting a second editor.
if port_open; then
	echo ">> Angelscript debug server already listening on $PORT — reusing it."
	exit 0
fi

mkdir -p "$(dirname "$LOG")"
echo ">> Launching $MODE: $UE_EDITOR ${ARGS[*]}"
echo ">> Log: $LOG"
setsid nohup "$UE_EDITOR" "${ARGS[@]}" > "$LOG" 2>&1 < /dev/null &
PID=$!
disown "$PID" 2>/dev/null

# A script compile error opens a modal that blocks frame 0 forever, even with -unattended,
# so treat it as a hard failure instead of sitting here until the timeout.
DEADLINE=$(( SECONDS + TIMEOUT ))
while [ "$SECONDS" -lt "$DEADLINE" ]; do
	if port_open; then
		echo ">> Angelscript debug server listening on $PORT — ready after ${SECONDS}s."
		exit 0
	fi
	if ! kill -0 "$PID" 2>/dev/null; then
		echo "ERROR: $MODE exited before the debug server came up. Last lines:" >&2
		tail -20 "$LOG" >&2
		exit 1
	fi
	if grep -q "Angelscript: Error" "$LOG" 2>/dev/null; then
		echo "ERROR: Angelscript compile errors — fix these, the editor is stuck on them:" >&2
		grep -A2 "Angelscript: Error" "$LOG" | head -40 >&2
		kill "$PID" 2>/dev/null
		exit 1
	fi
	sleep 1
done

echo "ERROR: timed out after ${TIMEOUT}s waiting for port $PORT. Last lines:" >&2
tail -20 "$LOG" >&2
exit 1
