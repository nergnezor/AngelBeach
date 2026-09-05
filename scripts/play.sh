#!/usr/bin/env bash
# Launch the standalone game (no editor UI) for actually playing.
#
# This wraps a few NixOS-specific workarounds discovered getting UnrealEditor
# to run on a system with no FHS /usr/lib:
#   - LD_LIBRARY_PATH picks up glib/gtk/dbus/gbm/etc. from `nix profile install`
#     (see the project README/CLAUDE.md for the package list) since the engine
#     binary expects them at standard system paths that don't exist here.
#   - VK_ICD_FILENAMES points explicitly at the NVIDIA Vulkan ICD. Without it
#     the Vulkan loader can't find a usable device and UE blocks forever on a
#     "Vulkan device could not be created" dialog.
#   - DISPLAY: UE's SDL backend needs XWayland (niri has no native-Wayland
#     windowing support built in), so DISPLAY must point at the XWayland
#     bridge (xwayland-satellite) even under a launcher that doesn't export
#     it itself — without this SDL fails outright with "No available video
#     device" and the process exits in well under a second.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPROJECT="$PROJECT_DIR/BeachVolleyball.uproject"
UE_EDITOR="${ENGINE_DIR:-$HOME/UnrealEngine-Angelscript}/Engine/Binaries/Linux/UnrealEditor"
MAP="${MAP:-/Game/CourtLevel}"

export LD_LIBRARY_PATH="$HOME/.nix-profile/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export VK_ICD_FILENAMES="/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json"
export DISPLAY="${DISPLAY:-:0}"

# Extra args pass straight through, so e.g. `play.sh -lightgraphics` starts in
# the reduced render (see ABeachVolleyballGameMode).
exec "$UE_EDITOR" "$UPROJECT" "$MAP" -game -asdebugport=27110 \
	-as-development-mode -windowed -ResX=1600 -ResY=900 "$@"
