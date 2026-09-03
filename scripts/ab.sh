#!/usr/bin/env bash
# Run the headless match N times and print the SPREAD of every gated metric.
#
# This exists because a single run cannot resolve a gameplay change here and
# pretending otherwise cost most of a day. Measured over three runs of
# IDENTICAL code, contacts per rally came out 3.00, 3.31 and 3.87. On
# 2026-09-02/03 a promising n=1 result was found to be noise three separate
# times, twice after it had already been acted on.
#
# So this never prints a single run's number on its own: every metric is shown
# as min/median/max across the runs, and two configurations are compared by
# whether their ranges OVERLAP, not by their means.
#
#   ./scripts/ab.sh                 3 runs, label "run"
#   ./scripts/ab.sh 5 before        5 runs, logs at /tmp/ab-before-*.log
#   ./scripts/ab.sh 3 after && ./scripts/ab.sh --compare before after
#
# Per-frame telemetry (hip reversals, pelvis slide) is stable from one run —
# it averages thousands of frames. Rally-level counts are not. The report marks
# which is which.
set -uo pipefail

UE="${ENGINE_DIR:-$HOME/UnrealEngine-Angelscript}/Engine/Binaries/Linux/UnrealEditor"
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/BeachVolleyball.uproject"

if [ "${1:-}" = "--compare" ]; then
	python3 "$(dirname "${BASH_SOURCE[0]}")/ab_report.py" "$2" "$3"
	exit $?
fi

N="${1:-3}"
LABEL="${2:-run}"

# The GPU holds one -game client at a time on 8GB. A second one dies in the RHI
# at frame 0, which looks exactly like a code failure and is not.
if pgrep -x UnrealEditor > /dev/null; then
	echo "ERROR: UnrealEditor is already running — close it first (8GB VRAM fits one client)." >&2
	exit 1
fi

rm -f "/tmp/ab-$LABEL-"*.log
for i in $(seq 1 "$N"); do
	LOG="/tmp/ab-$LABEL-$i.log"
	echo ">> run $i/$N -> $LOG"
	timeout -k 20 330 "$UE" "$PROJ" "/Game/CourtLevel" \
		-game -RenderOffscreen -resx=1280 -resy=720 -nosplash -unattended \
		"-ini:Engine:[/Script/Engine.RendererSettings]:r.RayTracing=False" \
		-abslog="$LOG" > /dev/null 2>&1
	ERRS=$(grep -c "Angelscript: Error" "$LOG" 2>/dev/null || echo 0)
	if [ "$ERRS" -gt 0 ]; then
		echo "   SCRIPT ERRORS ($ERRS) — the build did not compile:" >&2
		grep -m4 -A1 "Angelscript: Error" "$LOG" >&2
		exit 1
	fi
done

python3 "$(dirname "${BASH_SOURCE[0]}")/ab_report.py" "$LABEL"
