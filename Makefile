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
# Override any variable, e.g.:
#   make engine ENGINE_BRANCH=master JOBS=8
# =============================================================================

# --- Configuration -----------------------------------------------------------
ENGINE_DIR    ?= $(HOME)/UnrealEngine-Angelscript
ENGINE_REPO   ?= git@github.com:Hazelight/UnrealEngine-Angelscript.git
# Branch of the engine fork. `angelscript-master` is the default branch and
# tracks the latest supported UE version.
ENGINE_BRANCH ?= angelscript-master

PROJECT_NAME  := BeachVolleyball
PROJECT_DIR   := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
UPROJECT      := $(PROJECT_DIR)/$(PROJECT_NAME).uproject

# Leave 2 cores free so the box stays usable while building.
JOBS          ?= $(shell n=$$(nproc); echo $$((n>2 ? n-2 : 1)))

UE_EDITOR     := $(ENGINE_DIR)/Engine/Binaries/Linux/UnrealEditor
UE_BUILD      := $(ENGINE_DIR)/Engine/Build/BatchFiles/Linux/Build.sh
UE_GENPROJ    := $(ENGINE_DIR)/GenerateProjectFiles.sh
UE_UAT        := $(ENGINE_DIR)/Engine/Build/BatchFiles/RunUAT.sh

OUTPUT_DIR    ?= $(PROJECT_DIR)/PackagedBuilds

SWAPFILE      ?= /swapfile.ue
SWAPSIZE      ?= 32G

# --- Meta --------------------------------------------------------------------
.DEFAULT_GOAL := help
.PHONY: help deps swap engine project genproject run package-linux package-android package-web clean-project distclean check

help: ## Show this help
	@echo "Beach Volleyball — UE5 + AngelScript"
	@echo
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Engine dir : $(ENGINE_DIR)"
	@echo "Engine repo: $(ENGINE_REPO) ($(ENGINE_BRANCH))"
	@echo "Project    : $(UPROJECT)"
	@echo "Build jobs : $(JOBS)"

all: deps engine project ## deps + engine + project (skips swap)

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

# --- Optional swap (you have 14G RAM; UE linking can OOM) ---------------------
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
	@echo ">> Engine build complete: $(UE_EDITOR)"

# --- Project: compile the game's C++ module ----------------------------------
project: check ## Compile this game's C++ module against the engine
	@echo ">> Building $(PROJECT_NAME)Editor (Development|Linux)..."
	"$(UE_BUILD)" $(PROJECT_NAME)Editor Linux Development \
		-project="$(UPROJECT)" -progress
	@echo ">> Project module built."

package-linux: check ## Package a Development build for Linux (output: $(OUTPUT_DIR)/Linux)
	@mkdir -p "$(OUTPUT_DIR)/Linux"
	"$(UE_UAT)" BuildCookRun \
		-project="$(UPROJECT)" \
		-noP4 \
		-platform=Linux \
		-clientconfig=Development \
		-cook -build -stage -pak -archive \
		-archivedirectory="$(OUTPUT_DIR)/Linux"
	@echo ">> Linux package ready at $(OUTPUT_DIR)/Linux"

package-android: check ## Package a Development APK for Android (output: $(OUTPUT_DIR)/Android)
	@mkdir -p "$(OUTPUT_DIR)/Android"
	"$(UE_UAT)" BuildCookRun \
		-project="$(UPROJECT)" \
		-noP4 \
		-platform=Android \
		-cookflavor=Multi \
		-clientconfig=Development \
		-cook -build -stage -pak -archive \
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
		-archivedirectory="$(OUTPUT_DIR)/Web"
	@echo ">> Web package ready at $(OUTPUT_DIR)/Web/HTML5"

genproject: check ## (Optional) generate IDE project files for this project
	"$(UE_GENPROJ)" -project="$(UPROJECT)" -game -engine

# --- Run ---------------------------------------------------------------------
run: check ## Launch the editor on this project
	@echo ">> Launching UnrealEditor on $(PROJECT_NAME)..."
	"$(UE_EDITOR)" "$(UPROJECT)"

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

# --- Guard -------------------------------------------------------------------
check:
	@test -x "$(UE_EDITOR)" || { \
		echo "ERROR: engine not built at $(UE_EDITOR)"; \
		echo "       Run 'make engine' first."; exit 1; }
