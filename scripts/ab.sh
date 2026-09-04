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
#
# WHY THE RUNS ARE HEADLESS *AND* OFF THE CLOCK. Three separate things used to
# make a 3-run A/B cost 16 minutes, and none of them were the simulation:
#
#   1. It rendered. -RenderOffscreen still builds a Vulkan device, compiles
#      shaders and draws 1280x720 that nobody looks at. -nullrhi removes the
#      renderer entirely; the AI, the ball physics and the anim/IK evaluation
#      the telemetry measures are all game-thread work and are unaffected.
#   2. It ran in REAL TIME. Without a fixed time step the match plays at one
#      second of volleyball per second of your life, so the wall clock — not
#      the machine — set the sample size. -UseFixedTimeStep -FPS=60 advances
#      the sim exactly 1/60s per frame as fast as the CPU can tick it (~8x).
#   3. It never finished. Every run was KILLED by `timeout` mid-rally
#      (ReturnCode=143), so "how much match did I measure" drifted with
#      machine load. -seconds= ends the run after a fixed amount of SIMULATED
#      time, which is the honest sample size and is identical run to run.
#
# 330 simulated seconds is kept as the sample size. Runs are parallel because
# with no renderer there is no GPU to contend for. Measured: 3 runs, 16.5 min
# -> ~2.5, and the sample stopped drifting: the old timeout-killed runs covered
# 15-22 rallies depending on machine load, these cover 23-25 every time.
#
# BASELINES TAKEN BEFORE THIS CHANGE ARE NOT COMPARABLE, and the reason is a
# real property of the game rather than a harness detail: the simulation is
# FRAME-RATE SENSITIVE. Contacts per rally measured 4.59-4.80 free-running at
# ~140Hz, 3.92-4.39 at a fixed 120Hz and 3.54-4.21 at 60Hz — the arm bones only
# move once per frame while the ball substeps at 20ms, so a coarser tick misses
# contacts. (Worth remembering when the target is a 60fps phone.) Retake any
# baseline with this script before comparing against it; at 2.5 minutes a run
# that is cheap. AB_FPS must be identical on both sides of a comparison.
set -uo pipefail

# Same NixOS workarounds play.sh documents: the engine binary looks for glib &
# friends at FHS paths this system does not have, and the Vulkan loader needs to
# be pointed at the NVIDIA ICD explicitly. Without these the runs die before the
# log file is even opened, which reads as "no runs found" — i.e. exactly like a
# missing measurement rather than a broken launch.
export LD_LIBRARY_PATH="$HOME/.nix-profile/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export VK_ICD_FILENAMES="${VK_ICD_FILENAMES:-/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json}"

UE="${ENGINE_DIR:-$HOME/UnrealEngine-Angelscript}/Engine/Binaries/Linux/UnrealEditor"
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/BeachVolleyball.uproject"

if [ "${1:-}" = "--compare" ]; then
	python3 "$(dirname "${BASH_SOURCE[0]}")/ab_report.py" "$2" "$3"
	exit $?
fi

N="${1:-3}"
LABEL="${2:-run}"
# Simulated match seconds per run (NOT wall clock — see the header).
SECS="${AB_SECONDS:-330}"
# Fixed tick rate. NOT a free choice: the sim is frame-rate sensitive (measured —
# 60Hz and 120Hz give different contact rates and pelvis slide), so this is part
# of the measurement definition. Every baseline must be taken at the same value.
FPS="${AB_FPS:-120}"

# No renderer means no VRAM to fight over, so a live editor no longer breaks a
# run — it only steals CPU, which changes how long the measurement takes and
# not what it says. Worth saying out loud rather than silently competing.
if pgrep -x UnrealEditor > /dev/null; then
	echo "NOTE: UnrealEditor is already running; the nullrhi runs will share CPU with it." >&2
fi

rm -f "/tmp/ab-$LABEL-"*.log
PIDS=()
for i in $(seq 1 "$N"); do
	LOG="/tmp/ab-$LABEL-$i.log"
	echo ">> run $i/$N -> $LOG"
	# The timeout is a SAFETY NET only: -seconds= is what ends a healthy run.
	# If a run hits the timeout, something hung — the log will say so.
	timeout -k 20 600 "$UE" "$PROJ" "/Game/CourtLevel" \
		-game -nullrhi -nosplash -unattended \
		-UseFixedTimeStep "-FPS=$FPS" "-seconds=$SECS" \
		-abslog="$LOG" > /dev/null 2>&1 &
	PIDS+=($!)
done
for P in "${PIDS[@]}"; do wait "$P"; done

FAILED=0
for i in $(seq 1 "$N"); do
	LOG="/tmp/ab-$LABEL-$i.log"
	# grep -c prints 0 AND exits 1 when there are no matches, so `|| echo 0`
	# would append a second line and break the test below.
	ERRS=$(grep -c "Angelscript: Error" "$LOG" 2>/dev/null || true)
	ERRS=${ERRS:-0}
	if [ "$ERRS" -gt 0 ]; then
		echo "   run $i: SCRIPT ERRORS ($ERRS) — the build did not compile:" >&2
		grep -m4 -A1 "Angelscript: Error" "$LOG" >&2
		FAILED=1
	fi
done
[ "$FAILED" -eq 0 ] || exit 1

python3 "$(dirname "${BASH_SOURCE[0]}")/ab_report.py" "$LABEL"
