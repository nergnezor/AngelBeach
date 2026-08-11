# =============================================================================
# Beach Volleyball — build/run automation for Unreal Engine 5 + AngelScript
# =============================================================================
#
# This project needs the *AngelScript fork* of Unreal Engine (Hazelight's
# `UnrealEngine-Angelscript`), which is a full UE source tree — not a plugin.
#
# IMPORTANT — GitHub/Epic access:
#   The engine repo is a PRIVATE mirror of Epic's Unreal source. To clone it
#   your GitHub account must be linked to Epic Games and a member of the
#   `EpicGames` org. One-time setup (free):
#       https://www.unrealengine.com/en-US/ue-on-github
#
# Quick start:
#   make deps        # apt build dependencies (uses sudo)
#   make swap        # OPTIONAL: 32G swapfile (recommended, you have 14G RAM)
#   make engine      # clone + build the AngelScript UE fork (~100GB, hours)
#   make project     # compile this game's C++ module against that engine
#   make run         # launch the editor on CourtLevel
#
#   make all         # deps -> engine -> project   (does NOT touch swap)
#
# Android:
#   make package-android   # package APK into PackagedBuilds/Android
#   make android           # alias for package-android
#
# Override any variable, e.g.:
#   make engine ENGINE_BRANCH=master JOBS=8
# =============================================================================

# --- Configuration -----------------------------------------------------------
ENGINE_DIR    ?= $(HOME)/UnrealEngine-Angelscript
ENGINE_REPO   ?= git@github.com:Hazelight/UnrealEngine-Angelscript.git
ENGINE_BRANCH ?= angelscript-master

PROJECT_NAME  := BeachVolleyball
PROJECT_DIR   := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
UPROJECT      := $(PROJECT_DIR)/$(PROJECT_NAME).uproject

JOBS          ?= $(shell n=$$(nproc); echo $$((n>2 ? n-2 : 1)))

UE_EDITOR     := $(ENGINE_DIR)/Engine/Binaries/Linux/UnrealEditor
UE_BUILD      := $(ENGINE_DIR)/Engine/Build/BatchFiles/Linux/Build.sh
UE_GENPROJ    := $(ENGINE_DIR)/GenerateProjectFiles.sh
UE_UAT        := $(ENGINE_DIR)/Engine/Build/BatchFiles/RunUAT.sh

OUTPUT_DIR    ?= $(PROJECT_DIR)/PackagedBuilds

SWAPFILE      ?= /swapfile.ue
SWAPSIZE      ?= 32G

# Android overrides if needed. Defaults point at a no-sudo home install:
#   SDK installed via cmdline-tools into ~/Android/Sdk (NDK 27.2 / android-34 /
#   build-tools 35.0.1 / cmake 3.22.1 — the versions UE 5.7 expects), and a
#   portable Temurin JDK 17 in ~/jdk17 (UE Android tooling requires JDK 17, not
#   the system's newer JDK). Override on the command line if your layout differs.
ANDROID_HOME      ?= $(HOME)/Android/Sdk
ANDROID_NDK_HOME  ?= $(HOME)/Android/Sdk/ndk/27.2.12479018
JAVA_HOME         ?= $(HOME)/jdk17

# --- Meta --------------------------------------------------------------------
.DEFAULT_GOAL := help
.PHONY: help deps swap engine tools project genproject run run-game run-packaged package-linux package-android android clean-project distclean check all

help: ## Show this help
	@echo "Beach Volleyball — UE5 + AngelScript"
	@echo
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Engine dir : $(ENGINE_DIR)"
	@echo "Engine repo: $(ENGINE_REPO) ($(ENGINE_BRANCH))"
	@echo "Project    : $(UPROJECT)"
	@echo "Build jobs : $(JOBS)"

all: deps engine project ## deps + engine + project (skips swap)

android: package-android ## Alias for package-android

# --- System dependencies -----------------------------------------------------
deps: ## Install apt build dependencies (sudo)
	@echo ">> Installing build dependencies via apt..."
	sudo apt-get update
	sudo apt-get install -y --no-install-recommends \
		git build-essential clang lld cmake \
		mono-complete \
		libssl-dev zlib1g-dev \
		xdg-user-dirs xdg-utils \
		python3 curl ca-certificates
	@echo ">> deps OK."

# --- Optional swap -----------------------------------------------------------
swap: ## Create a $(SWAPSIZE) swapfile at $(SWAPFILE) (sudo, optional)
	@if swapon --show | grep -q "$(SWAPFILE)"; then \
		echo ">> swap already active at $(SWAPFILE)"; \
	else \
		echo ">> Creating $(SWAPSIZE) swapfile at $(SWAPFILE)..."; \
		sudo fallocate -l $(SWAPSIZE) $(SWAPFILE) || sudo dd if=/dev/zero of=$(SWAPFILE) bs=1M count=32768; \
		sudo chmod 600 $(SWAPFILE); \
		sudo mkswap $(SWAPFILE); \
		sudo swapon $(SWAPFILE); \
		echo ">> swap on. (Not persisted across reboot — add to /etc/fstab if you want that.)"; \
	fi
	@free -h | grep -i swap

# --- Engine: clone + build ---------------------------------------------------
engine: ## Clone + build the AngelScript UE fork (~100GB, hours)
	@if [ ! -d "$(ENGINE_DIR)/.git" ]; then \
		echo ">> Cloning $(ENGINE_REPO) ($(ENGINE_BRANCH)) into $(ENGINE_DIR)"; \
		echo ">> NOTE: requires GitHub linked to the EpicGames org (see header)."; \
		git clone --depth 1 --branch $(ENGINE_BRANCH) $(ENGINE_REPO) "$(ENGINE_DIR)" || { \
			echo "ERROR: clone failed. Most likely your GitHub account is not a"; \
			echo "       member of the EpicGames org. Set this up (free) at:"; \
			echo "       https://www.unrealengine.com/en-US/ue-on-github"; \
			exit 1; }; \
	else \
		echo ">> Engine already present at $(ENGINE_DIR); skipping clone."; \
	fi
	@echo ">> Running Setup.sh (downloads toolchain + dependencies)..."
	cd "$(ENGINE_DIR)" && ./Setup.sh
	@echo ">> Generating engine project files..."
	cd "$(ENGINE_DIR)" && ./GenerateProjectFiles.sh
	@echo ">> Building editor (this is the long part)..."
	cd "$(ENGINE_DIR)" && $(MAKE) -j$(JOBS) UnrealEditor
	@$(MAKE) tools
	@echo ">> Engine build complete: $(UE_EDITOR)"

# --- Engine helper programs --------------------------------------------------
tools: ## Build ShaderCompileWorker + Lightmass + InterchangeWorker
	@echo ">> Building helper programs (ShaderCompileWorker is required to render)..."
	cd "$(ENGINE_DIR)" && $(MAKE) -j$(JOBS) ShaderCompileWorker
	cd "$(ENGINE_DIR)" && $(MAKE) -j$(JOBS) UnrealLightmass
	cd "$(ENGINE_DIR)" && $(MAKE) -j$(JOBS) InterchangeWorker
	@echo ">> Helper programs built."

# --- Guard -------------------------------------------------------------------
check:
	@test -x "$(UE_EDITOR)" || { \
		echo "ERROR: engine not built at $(UE_EDITOR)"; \
		echo "       Run 'make engine' first."; exit 1; }
	@test -f "$(UPROJECT)" || { \
		echo "ERROR: project file not found: $(UPROJECT)"; \
		exit 1; }

# --- Project: compile --------------------------------------------------------
project: check ## Compile this game's C++ module against the engine
	@echo ">> Building $(PROJECT_NAME)Editor (Development|Linux)..."
	"$(UE_BUILD)" $(PROJECT_NAME)Editor Linux Development \
		-project="$(UPROJECT)" -progress
	@echo ">> Project module built."

# --- Package -----------------------------------------------------------------
package-linux: check ## Package a Development build for Linux (output: $(OUTPUT_DIR)/Linux)
	@mkdir -p "$(OUTPUT_DIR)/Linux"
	"$(UE_UAT)" BuildCookRun \
		-project="$(UPROJECT)" \
		-noP4 \
		-platform=Linux \
		-clientconfig=Development \
		-cook -build -stage -pak -archive \
		-nozenstore \
		-archivedirectory="$(OUTPUT_DIR)/Linux"
	@echo ">> Linux package ready at $(OUTPUT_DIR)/Linux"

package-android: check ## Package a Development APK for Android (output: $(OUTPUT_DIR)/Android)
	@test -d "$(ANDROID_HOME)" || { \
		echo "ERROR: ANDROID_HOME not found: $(ANDROID_HOME)"; \
		exit 1; }
	@test -d "$(ANDROID_NDK_HOME)" || { \
		echo "ERROR: ANDROID_NDK_HOME not found: $(ANDROID_NDK_HOME)"; \
		exit 1; }
	@echo ">> Removing stale Android cook, stage, and archive output..."
	rm -rf "$(PROJECT_DIR)/Saved/Cooked/Android"* \
		"$(PROJECT_DIR)/Saved/StagedBuilds/Android"* \
		"$(OUTPUT_DIR)/Android"
	@mkdir -p "$(OUTPUT_DIR)/Android"
	ANDROID_HOME="$(ANDROID_HOME)" \
	ANDROID_SDK_ROOT="$(ANDROID_HOME)" \
	NDKROOT="$(ANDROID_NDK_HOME)" \
	NDK_ROOT="$(ANDROID_NDK_HOME)" \
	ANDROID_NDK_ROOT="$(ANDROID_NDK_HOME)" \
	JAVA_HOME="$(JAVA_HOME)" \
	"$(UE_UAT)" BuildCookRun \
		-project="$(UPROJECT)" \
		-noP4 \
		-platform=Android \
		-cookflavor=Multi \
		-clientconfig=Development \
		-cook -build -stage -pak -package -archive \
		-nozenstore \
		-archivedirectory="$(OUTPUT_DIR)/Android"
	@echo ">> Android package ready at $(OUTPUT_DIR)/Android"

package-web: check ## Package for HTML5/WebGL (output: $(OUTPUT_DIR)/Web) — requires community HTML5 plugin
	@test -d "$(ENGINE_DIR)/Engine/Platforms/HTML5" || { \
		echo "ERROR: HTML5 platform not found."; \
		echo "       Install the community plugin: https://github.com/nicktindall/ue5-html5-plugin"; \
		exit 1; }
	@mkdir -p "$(OUTPUT_DIR)/Web"
	"$(UE_UAT)" BuildCookRun \
		-project="$(UPROJECT)" \
		-noP4 \
		-platform=HTML5 \
		-clientconfig=Development \
		-cook -build -stage -pak -archive \
		-nozenstore \
		-archivedirectory="$(OUTPUT_DIR)/Web"
	@echo ">> Web package ready at $(OUTPUT_DIR)/Web/HTML5"

# --- Run ---------------------------------------------------------------------
genproject: check ## (Optional) generate IDE project files for this project
	"$(UE_GENPROJ)" -project="$(UPROJECT)" -game -engine

run: check ## Launch the editor on this project
	@echo ">> Launching UnrealEditor on $(PROJECT_NAME)..."
	"$(UE_EDITOR)" "$(UPROJECT)"

# Two ways to play WITHOUT the editor UI:
#
#   make run-game       fast loop. No cook, no packaging — the editor binary runs the
#                       game directly off the uncooked content (`-game`). Boots in about
#                       a minute, and the Angelscript debug server still listens on 27099
#                       so VSCode breakpoints work. Beware: a script compile error opens a
#                       modal that blocks frame 0 forever, even with -unattended.
#
#   make run-packaged   the real thing. A cooked standalone build with no engine editor in
#                       the loop at all — but `make package-linux` must produce it first
#                       (slow), and Angelscript is baked in, so no hot reload.
#
# Pass extra engine args through RUNARGS, e.g.
#   make run-game RUNARGS="-RenderOffscreen -nosplash -unattended"
RUNARGS ?=
MAP     ?= /Game/CourtLevel

run-game: check ## Play standalone off uncooked content — no editor UI, no cook (fast loop)
	@echo ">> Launching $(PROJECT_NAME) standalone on $(MAP)..."
	"$(UE_EDITOR)" "$(UPROJECT)" $(MAP) -game $(RUNARGS)

run-packaged: ## Run the cooked Linux build (needs 'make package-linux' first)
	@BIN=$$(find "$(OUTPUT_DIR)/Linux" -name '$(PROJECT_NAME).sh' -type f 2>/dev/null | head -1); \
	test -n "$$BIN" || { \
		echo "ERROR: no packaged Linux build under $(OUTPUT_DIR)/Linux"; \
		echo "       Run 'make package-linux' first."; exit 1; }; \
	echo ">> Running $$BIN"; \
	"$$BIN" $(RUNARGS)

# --- Cleanup -----------------------------------------------------------------
clean-project: ## Remove this project's generated build artifacts
	rm -rf "$(PROJECT_DIR)/Binaries" "$(PROJECT_DIR)/Intermediate" \
	       "$(PROJECT_DIR)/Saved" "$(PROJECT_DIR)/DerivedDataCache"
	@echo ">> Project build artifacts removed."

distclean: clean-project ## Also remove the entire engine checkout (DANGER)
	@echo ">> About to delete the engine at $(ENGINE_DIR)"
	@printf "   Type 'yes' to confirm: " && read ans && [ "$$ans" = "yes" ] \
		&& rm -rf "$(ENGINE_DIR)" && echo ">> engine removed." \
		|| echo ">> aborted."
