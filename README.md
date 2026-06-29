# Beach Volleyball — Unreal Engine 5 + AngelScript

A beach volleyball game built entirely with AngelScript and procedural mesh generation. No imported 3D models — all geometry is created at runtime.

## Features

- **Rally scoring** — sets 1 & 2 to 21 points, deciding set to 15 (2-point lead required)
- **Full physics** — Euler integration with gravity, air drag, floor bounce, net collision
- **Procedural geometry** — sphere (ball), flat quads (sand/net), lines, cylinders (posts)
- **AI opponent** — forward-integration trajectory prediction, adjustable difficulty (0–1)
- **HUD** — live score, set counter, game phase text, minimap
- **Side camera** — smooth ball-following with configurable weights
- **Golden-hour lighting** — low warm sun, real-time sky light, warm volumetric fog, post-process bloom/vignette/exposure
- **Sand FX** — grains spray upward on ball impacts and footsteps (Niagara when assigned, procedural CPU fallback otherwise)
- **Deformable sand** — impacts and footsteps dent craters and footprints that slowly heal
- **Gamepad support** — full controller bindings alongside keyboard

## Controls

| Keyboard | Gamepad | Action |
|----------|---------|--------|
| W/A/S/D | Left stick | Move |
| Space | A | Jump |
| E | X | Pass (bump) |
| Shift | Y | Set |
| F | B / Right trigger | Spike |
| Escape | Start | Pause |

## Project Structure

```
BeachVolleyball.uproject   — UE5 project file (AngelScript + ProceduralMeshComponent plugins)
Config/
  DefaultEngine.ini        — engine settings, default map, GameMode
  DefaultGame.ini          — project metadata
  DefaultInput.ini         — axis and action bindings
Source/BeachVolleyball/
  BeachVolleyball.h/.cpp   — minimal C++ module entry point
  BeachVolleyball.Build.cs — module dependencies
Script/
  GameState.as             — ETeam, EGamePhase, rally scoring, touch tracking
  Ball.as                  — physics, net/floor collision, procedural sphere mesh
  Player.as                — APawn base: movement, jump, pass/set/spike
  HumanPlayer.as           — WASD+Space+E+Shift+F input bindings
  AIPlayer.as              — AI with trajectory prediction, difficulty scaling
  Court.as                 — deformable sand grid, net, lines, posts (all procedural)
  SandFX.as                — upward sand spray + dust (Niagara or procedural fallback)
  GameMode.as              — world setup (golden-hour lighting, post-process, camera),
                             spawn, serve flow, point/set/match logic, restart
  HUD.as                   — Canvas HUD: score, phase, minimap
  Camera.as                — side-view camera with soft ball-following
Content/
  CourtLevel.umap          — near-empty level; GameMode builds everything at runtime
```

## Setup

This project targets the **AngelScript fork of Unreal Engine** (Hazelight's
`UnrealEngine-Angelscript`, latest branch). A `Makefile` automates the whole
build on Linux:

```bash
make deps        # apt build dependencies
make swap        # optional 32G swapfile (helps on <32G RAM)
make engine      # clone + build the AngelScript UE fork (needs EpicGames GitHub access)
make project     # compile the game module
make run         # launch the editor on this project
```

Then press Play — the `GameMode` builds the court, players, ball, lighting and
camera at runtime on the near-empty `CourtLevel` map. AngelScript hot-reloads,
so edits to `Script/*.as` apply without restarting.

## CI / Self-hosted runner

Builds run on a self-hosted GitHub Actions runner (`linux,ue5,self-hosted`).

### First-time runner registration

```bash
# 1. Download and extract the runner
mkdir ~/actions-runner && cd ~/actions-runner
curl -fsSL https://github.com/actions/runner/releases/latest/download/$(
  curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
  | grep -oP '"tag_name":\s*"v\K[^"]+' \
  | sed 's/.*/actions-runner-linux-x64-&.tar.gz/'
) -o runner.tar.gz
tar xzf runner.tar.gz && rm runner.tar.gz

# 2. Get a registration token (requires repo scope PAT or gh CLI)
TOKEN=$(gh api -X POST repos/nergnezor/AngelBeach/actions/runners/registration-token --jq '.token')

# 3. Configure
./config.sh \
  --url https://github.com/nergnezor/AngelBeach \
  --token "$TOKEN" \
  --name "$(hostname)" \
  --labels "linux,ue5,self-hosted" \
  --work "_work" \
  --unattended

# 4. Install as a systemd service (survives reboots)
sudo ./svc.sh install && sudo ./svc.sh start
```

### Runner environment (`~/actions-runner/.env`)

The runner must have these variables set so that subprocesses (Gradle, UBT)
inherit them regardless of which shell profile is loaded:

```
ANDROID_HOME=/home/erik/Android/Sdk
JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
```

After editing `.env`, restart the runner service:

```bash
sudo systemctl restart "actions.runner.*"
# or if running manually:  kill <pid> && cd ~/actions-runner && ./run.sh
```

### Repository variables

Set these under **Settings → Secrets and variables → Actions → Variables**:

| Variable | Example value |
|---|---|
| `ENGINE_DIR` | `/home/erik/UnrealEngine-Angelscript` |
| `ANDROID_HOME` | `/home/erik/Android/Sdk` |
| `ANDROID_NDK_HOME` | `/home/erik/Android/Sdk/ndk/27.3.13750724` |
| `JAVA_HOME` | `/usr/lib/jvm/java-17-openjdk-amd64` |

Update `ANDROID_NDK_HOME` if you install a different NDK version:

```bash
ls ~/Android/Sdk/ndk/   # shows installed version(s)
gh variable set ANDROID_NDK_HOME --body "/home/erik/Android/Sdk/ndk/<version>"
```

### Engine installation

The engine must be built once on the runner machine before CI can package:

```bash
git clone --depth 1 --branch angelscript-master \
  git@github.com:Hazelight/UnrealEngine-Angelscript.git \
  ~/UnrealEngine-Angelscript
cd ~/UnrealEngine-Angelscript
./Setup.sh
./GenerateProjectFiles.sh
make -j$(( $(nproc) - 2 )) UnrealEditor   # takes 1–3 h
```

Requires your GitHub account to be linked to the EpicGames organisation
(free: <https://www.unrealengine.com/en-US/ue-on-github>).

## Scoring Rules

- Points awarded on: ball landing in bounds, touch violations (> 3 touches per side)
- Serving team: winner of last point
- Sides switch each set
- Best of 3 sets wins the match

## AI Difficulty

Adjust `AAIPlayer.Difficulty` (0.0–1.0) in `Script/AIPlayer.as`:
- `0.0` — very slow, large positional error
- `0.7` — default, competitive
- `1.0` — near-perfect prediction, fastest movement

## Sand FX (Niagara, optional)

Sand spray works out of the box via a procedural CPU particle fallback — no
assets required. For the most realistic GPU sand, author Niagara systems in the
editor and assign them on the `ASandFX` actor:

1. Create a Niagara System (e.g. `NS_SandBurst`) — a short-lived burst emitter
   with a strong upward + outward initial velocity, gravity, and collision.
   Optionally a second smaller system (`NS_Footstep`) for footstep puffs.
2. Open `Script/SandFX.as` and set the defaults of `ImpactSystem` /
   `FootstepSystem`, or assign them on the spawned `ASandFX` instance.
3. When a system is assigned it is used automatically; otherwise the procedural
   fallback runs. Tune spray strength/counts in `SandFX::SprayFallback`.

Crater/footprint depth and heal speed live in `Script/Court.as`
(`SandMinZ`, `SandHealRate`, `DeformSand`).
