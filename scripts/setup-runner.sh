#!/usr/bin/env bash
# =============================================================================
# Angel Beach – self-hosted runner setup
#
# Installs all build dependencies on a fresh Ubuntu 22.04/24.04 machine and
# registers it as a GitHub Actions self-hosted runner.
#
# Required environment variables:
#   REPO             GitHub repo, e.g. nergnezor/AngelBeach
#   RUNNER_TOKEN     Registration token from:
#                    Settings → Actions → Runners → New self-hosted runner
#
# Optional environment variables:
#   ENGINE_DIR       Where to clone the UE fork  (default: /opt/UnrealEngine-Angelscript)
#   RUNNER_DIR       Where to install the runner  (default: /opt/actions-runner)
#   RUNNER_LABELS    Comma-separated extra labels (default: linux,ue5)
#   ENGINE_BRANCH    Engine git branch            (default: angelscript-master)
#   ENGINE_REPO      SSH URL of engine repo       (default: git@github.com:Hazelight/UnrealEngine-Angelscript.git)
#   JOBS             Parallel build jobs          (default: nproc-2)
#   ANDROID_SDK_DIR  Android SDK root             (default: /opt/android-sdk)
#   SKIP_ENGINE      Set to 1 to skip engine build (if already installed)
#   SKIP_ANDROID     Set to 1 to skip Android SDK
#   SKIP_HTML5       Set to 1 to skip HTML5 plugin
#
# Usage (interactive):
#   export REPO=nergnezor/AngelBeach
#   export RUNNER_TOKEN=<token from GitHub>
#   bash setup-runner.sh
#
# The script is idempotent: already-installed components are skipped.
# =============================================================================
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
REPO="${REPO:?'REPO is required, e.g. nergnezor/AngelBeach'}"
RUNNER_TOKEN="${RUNNER_TOKEN:?'RUNNER_TOKEN is required (GitHub → Settings → Actions → Runners)'}"

ENGINE_DIR="${ENGINE_DIR:-/opt/UnrealEngine-Angelscript}"
RUNNER_DIR="${RUNNER_DIR:-/opt/actions-runner}"
RUNNER_LABELS="${RUNNER_LABELS:-linux,ue5}"
ENGINE_BRANCH="${ENGINE_BRANCH:-angelscript-master}"
ENGINE_REPO="${ENGINE_REPO:-git@github.com:Hazelight/UnrealEngine-Angelscript.git}"
ANDROID_SDK_DIR="${ANDROID_SDK_DIR:-/opt/android-sdk}"
JOBS="${JOBS:-$(( $(nproc) > 2 ? $(nproc) - 2 : 1 ))}"

SKIP_ENGINE="${SKIP_ENGINE:-0}"
SKIP_ANDROID="${SKIP_ANDROID:-0}"
SKIP_HTML5="${SKIP_HTML5:-0}"

LOG="/var/log/setup-runner.log"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
step() { echo; log "==> $*"; }
ok()   { log "    OK: $*"; }

step "Starting Angel Beach runner setup (log: $LOG)"
log "  Repo:          $REPO"
log "  Engine dir:    $ENGINE_DIR"
log "  Runner dir:    $RUNNER_DIR"
log "  Runner labels: $RUNNER_LABELS"

# ── 1. System packages ────────────────────────────────────────────────────────
step "Installing system packages"
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
    git build-essential clang lld cmake \
    mono-complete \
    libssl-dev zlib1g-dev \
    xdg-user-dirs xdg-utils \
    python3 curl ca-certificates wget unzip \
    openjdk-17-jdk \
    tmux
ok "System packages installed"

# ── 2. Swapfile (32 GB – UE5 linker needs it) ─────────────────────────────────
SWAPFILE="/swapfile.ue"
step "Swapfile"
if swapon --show | grep -q "$SWAPFILE"; then
    ok "Swap already active at $SWAPFILE"
else
    log "Creating 32G swapfile at $SWAPFILE ..."
    sudo fallocate -l 32G "$SWAPFILE" 2>/dev/null \
        || sudo dd if=/dev/zero of="$SWAPFILE" bs=1M count=32768 status=progress
    sudo chmod 600 "$SWAPFILE"
    sudo mkswap "$SWAPFILE"
    sudo swapon "$SWAPFILE"
    # Persist across reboots
    grep -qF "$SWAPFILE" /etc/fstab \
        || echo "$SWAPFILE none swap sw 0 0" | sudo tee -a /etc/fstab
    ok "Swapfile active"
fi

# ── 3. Unreal Engine (AngelScript fork) ───────────────────────────────────────
step "Unreal Engine"
if [ "$SKIP_ENGINE" = "1" ]; then
    log "SKIP_ENGINE=1 — skipping engine build"
elif [ -x "$ENGINE_DIR/Engine/Binaries/Linux/UnrealEditor" ]; then
    ok "Engine already built at $ENGINE_DIR"
else
    # Clone
    if [ ! -d "$ENGINE_DIR/.git" ]; then
        log "Cloning $ENGINE_REPO ($ENGINE_BRANCH) → $ENGINE_DIR"
        log "NOTE: requires your GitHub account to be in the EpicGames org."
        log "      One-time setup (free): https://www.unrealengine.com/en-US/ue-on-github"
        sudo mkdir -p "$(dirname "$ENGINE_DIR")"
        sudo chown "$USER:$USER" "$(dirname "$ENGINE_DIR")"
        git clone --depth 1 --branch "$ENGINE_BRANCH" "$ENGINE_REPO" "$ENGINE_DIR"
    else
        ok "Engine repo already present, skipping clone"
    fi

    log "Running Setup.sh ..."
    cd "$ENGINE_DIR"
    ./Setup.sh

    log "Generating project files ..."
    ./GenerateProjectFiles.sh

    log "Building UnrealEditor (this takes 1–3 hours) ..."
    make -j"$JOBS" UnrealEditor
    ok "Engine built: $ENGINE_DIR/Engine/Binaries/Linux/UnrealEditor"
fi

# ── 4. Android SDK + NDK ──────────────────────────────────────────────────────
step "Android SDK / NDK"
CMDLINE_TOOLS="$ANDROID_SDK_DIR/cmdline-tools/latest/bin/sdkmanager"
if [ "$SKIP_ANDROID" = "1" ]; then
    log "SKIP_ANDROID=1 — skipping Android SDK"
elif [ -f "$CMDLINE_TOOLS" ]; then
    ok "Android SDK already at $ANDROID_SDK_DIR"
else
    log "Downloading Android command-line tools ..."
    sudo mkdir -p "$ANDROID_SDK_DIR/cmdline-tools"
    sudo chown -R "$USER:$USER" "$ANDROID_SDK_DIR"

    TMP_ZIP="/tmp/cmdline-tools.zip"
    wget -q "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" \
        -O "$TMP_ZIP"
    unzip -q "$TMP_ZIP" -d "$ANDROID_SDK_DIR/cmdline-tools/"
    mv "$ANDROID_SDK_DIR/cmdline-tools/cmdline-tools" \
       "$ANDROID_SDK_DIR/cmdline-tools/latest"
    rm "$TMP_ZIP"

    log "Accepting licenses and installing SDK/NDK ..."
    yes | "$CMDLINE_TOOLS" --licenses > /dev/null 2>&1 || true
    "$CMDLINE_TOOLS" \
        "platform-tools" \
        "platforms;android-34" \
        "build-tools;34.0.0" \
        "ndk;25.1.8937393"

    # Make env vars available to future runner sessions
    {
        echo "export ANDROID_HOME=$ANDROID_SDK_DIR"
        echo "export ANDROID_NDK_HOME=$ANDROID_SDK_DIR/ndk/25.1.8937393"
        echo "export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64"
        echo "export PATH=\$ANDROID_HOME/platform-tools:\$PATH"
    } | sudo tee /etc/profile.d/android-sdk.sh > /dev/null
    ok "Android SDK + NDK installed at $ANDROID_SDK_DIR"
fi

# ── 5. HTML5 community plugin ─────────────────────────────────────────────────
step "HTML5 platform plugin"
HTML5_DIR="$ENGINE_DIR/Engine/Platforms/HTML5"
if [ "$SKIP_HTML5" = "1" ]; then
    log "SKIP_HTML5=1 — skipping HTML5 plugin"
elif [ -d "$HTML5_DIR" ]; then
    ok "HTML5 plugin already present at $HTML5_DIR"
else
    log "Cloning community HTML5 plugin ..."
    git clone --depth 1 \
        https://github.com/nicktindall/ue5-html5-plugin.git \
        "$HTML5_DIR"
    ok "HTML5 plugin installed at $HTML5_DIR"
fi

# ── 6. GitHub Actions runner ──────────────────────────────────────────────────
step "GitHub Actions runner"
RUNNER_SCRIPT="$RUNNER_DIR/run.sh"
if [ -f "$RUNNER_SCRIPT" ]; then
    ok "Runner already installed at $RUNNER_DIR"
else
    log "Fetching latest runner release ..."
    RUNNER_VERSION=$(curl -fsSL \
        https://api.github.com/repos/actions/runner/releases/latest \
        | grep -oP '"tag_name":\s*"v\K[^"]+')
    RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"

    sudo mkdir -p "$RUNNER_DIR"
    sudo chown "$USER:$USER" "$RUNNER_DIR"
    cd "$RUNNER_DIR"

    log "Downloading runner v${RUNNER_VERSION} ..."
    curl -fsSL "$RUNNER_URL" -o actions-runner.tar.gz
    tar xzf actions-runner.tar.gz
    rm actions-runner.tar.gz

    log "Configuring runner ..."
    ./config.sh \
        --url "https://github.com/$REPO" \
        --token "$RUNNER_TOKEN" \
        --name "$(hostname)" \
        --labels "$RUNNER_LABELS" \
        --work "_work" \
        --unattended

    log "Installing runner as systemd service ..."
    sudo ./svc.sh install "$USER"
    sudo ./svc.sh start
    ok "Runner installed and started (systemd service: actions.runner.*)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
step "Setup complete"
log "Runner labels : $RUNNER_LABELS"
log "Engine        : $ENGINE_DIR"
log "Android SDK   : $ANDROID_SDK_DIR"
log "HTML5 plugin  : $ENGINE_DIR/Engine/Platforms/HTML5"
log "Runner dir    : $RUNNER_DIR"
log ""
log "Check runner status : sudo systemctl status \"actions.runner.*\""
log "Full log            : $LOG"
