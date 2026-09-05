# AngelBeach — beach volleyball (UE5.8, Hazelight Angelscript fork)

A beach volleyball game written almost entirely in Angelscript (`Script/*.as`).
Players are `APawn`s with a Manny skeletal mesh; a custom physics ball bounces off
their arm bones; AI plays structured volleyball (receive → set → attack).

## Build / reload workflow

- **Logic-only changes** (edit a method body): **Soft Reload** (Ctrl+Shift+F11) hot-reloads.
- **New member variable / UPROPERTY / changed spawn layout**: requires a **Full Reload**
  (Ctrl+Alt+F11 or restart editor) — soft reload will NOT pick it up.
- Logs: `Saved/Logs/BeachVolleyball.log`. Angelscript `Log()` lines are prefixed `Angelscript:`.

## Light graphics mode (B)

`B` toggles a stripped-down render of the same match — `ABeachVolleyballGameMode::
ToggleLightGraphics()`, bound in `AHumanPlayer` because a possessed pawn is the only
place script sees a keyboard in this fork. It hides the beach (sand, sea, coastline,
dunes, props, sand spray — court lines, net and posts stay) and paints every player
in a strong flat team tint (`AVolleyballPlayer::SetLightGraphics`).

**Where the frame time actually goes.** Hiding geometry barely moved it — this scene
is a handful of meshes; the cost is per-pixel. So the mode also:
- turns **all** of Lumen off, reflections included (`r.DynamicGlobalIlluminationMethod 0`,
  `r.ReflectionMethod 0`). Hardware-ray-traced reflections were the single most
  expensive pass in the frame. The level's reflection capture goes off with them
  (`r.ReflectionCapture.Runtime 0`): with no Lumen in front of it, the capture becomes
  the only specular source and clips every player, ring and line to white.
- freezes the SkyLight — `SetRealTimeCapture(false)` + one `RecaptureSky()` — instead
  of re-capturing and re-convolving a cubemap every frame for a sky that never changes.
  Do **not** use `r.SkyLight.RealTimeReflectionCapture 0` for this: it leaves the light
  without a valid cubemap and blows the whole scene out.
- renders at **50% screen percentage** (a quarter of the pixels, TSR upsamples back).
- caps at **60 fps** (`t.MaxFPS`). Uncapped, the GPU pins at 100% however cheap the
  scene is, which is what "light graphics isn't light" felt like.
- drops shadows — **both** `r.ShadowQuality 0` *and* `r.Shadow.Virtual.Enable 0`; the
  first does not reach virtual shadow maps, so on its own the shadow pass survives.
- drops clouds, bloom, film grain, motion blur, DOF and lens flare. **Eye adaptation
  stays on** even though it profiles large: the scene is graded for auto-exposure, and
  switching it off pins exposure where the image was never graded and blows it out.
- adds one shadowless directional fill light. With Lumen gone, the sun at pitch −45
  leaves the camera-facing side of a body almost black — the same failure mobile has
  (see the SkyLight block in `SetupWorld`).

Restore values are read from `Config/DefaultEngine.ini`, **not** the engine cvar
defaults: the engine ships GI=None/Reflections=SSR while this project asks for Lumen
on both, so restoring "defaults" would silently downgrade the normal look.

**Bisect renderer regressions in the mode that shows them.** The capture blow-out above
filmed perfectly fine in normal mode, because Lumen sits in front of the capture there.
A clean normal-mode frame proves nothing about a change that only light mode exposes.

## The court's reflection capture lives in CourtLevel

It used to be spawned at runtime, and was therefore never built: a capture's cubemap
comes from the map's MapBuildData, and this scene is assembled at runtime onto an empty
level. The editor hides that by handing an unbuilt capture *preview* data (hence
"REFLECTION CAPTURES NEED TO BE REBUILT" on screen) — preview data a packaged build does
not have, so shipped it contributed nothing. The fix is a **runtime capture**, and
`bRuntimeCapture` is `BlueprintReadOnly` with no setter anywhere in the engine, so it
cannot come from script: there is now a `SphereReflectionCapture` placed in
`CourtLevel.umap` with the box ticked. `GameMode` supplies the two halves script still
owns — `r.ReflectionCapture.Runtime 1` (without it a runtime-flagged capture is skipped
entirely) and one `RefreshCapture()` a second after `BeginPlay`, once.

Placing it was done head-less through the project's own MCP bridge, which is the way to
make editor-only asset changes from a terminal: `scripts/launch_ue.sh editor` (add
`EXTRA_ARGS="-RenderOffscreen -nosplash"`, and `AS_DEBUG_PORT=` if a headless match
already holds 27099), then `scripts/etapp5_mcp.py <command> <json>` for
`spawn_actor_from_class` / `set_actor_property` (it takes `component_name`) /
`save_asset`. The `unreal` server in `.mcp.json` is a different, unrelated thing and its
binary is not installed.

**A material assigned from script must have the right usage flag.** The players were
first rendered as mirror shells (BasicShapeMaterial, roughness 0.05). That works in
the *editor*, which sets usage flags for you on assignment, and renders as the black
**default material** in `-game`: `Material .../BasicShapeMaterial missing usage flag
SkeletalMesh! Default Material will be used in game.` Nothing in script can set that
flag, and a hand-authored material asset would be gitignored (`Content/*.uasset`) and
therefore missing on a fresh clone and in CI. Hence a tint on the mesh's own material.
Same trap for any future skeletal-mesh material swap — check the log, not the editor.

- **It is a rendering switch and nothing else** — no gameplay, physics or AI state
  reads it, so toggling mid-rally cannot change the result. Keep it that way.
- The sand heightfield stops healing/rebuilding while hidden and is rebuilt once on
  the way back, so footprints taken in light mode appear when it is switched off.
- No gamepad twin: the pad's B face button is already Spike. No touch button either
  (the HUD cluster is Jump/Pass/Set/Spike), so Android has no way in yet.

## Autonomous verification (headless — no human at the editor)

Two debug GameModes in `Script/Debug/` give a closed see-it-yourself loop:

- **PhotoBooth** (`APhotoBoothGameMode`): one player + frozen ball, cycles every hit
  pose, photographs each from 3 camera angles, logs hand-vs-ball / hand-vs-IK-target
  distances (`BOOTH` lines) so images pair with numbers.
- **MatchFilmer** (`AMatchFilmerGameMode`): the real match, one HighResShot every
  0.45s during rallies (`FILM` lines with ball pos/touches), quits after 60 shots.

Launch (screenshots land in `Saved/Screenshots/LinuxEditor/`):

    ~/UnrealEngine-Angelscript/Engine/Binaries/Linux/UnrealEditor BeachVolleyball.uproject \
      "/Game/CourtLevel?game=/Script/Angelscript.PhotoBoothGameMode" \
      -game -RenderOffscreen -resx=1280 -resy=720 -nosplash -unattended \
      -asdebugport=59999 -abslog=/tmp/run.log

Hard-won gotchas:
- **`-asdebugport=59999` is required**: otherwise the VSCode Angelscript debugger
  auto-attaches to the headless run and can pause it indefinitely.
- **A script compile error in `-game` opens a dialog that blocks frame 0 forever**
  (even with `-unattended`). If a run sits at frame `[  0]`, grep the log for
  `Angelscript: Error`. Always wrap runs in `timeout -k 15 <secs>`.
- **`-resx=1280 -resy=720` hung at frame 0; `-resx=640 -resy=360` runs.** Twice in a
  row, a MatchFilmer launch at 720p sat at frame `[  0]` until it was killed — no
  script errors, shader workers idle, the game thread spinning while the render
  thread waited on a futex. The same build at 640x360 completed 120 shots and quit
  cleanly, and the plain GameMode at 720p reached frame 999, so it is neither the
  scene nor the game code. **The screenshots are 1280x720 either way** — HighResShot
  renders at its own resolution, so nothing is lost by launching small.
- **`HighResShot` captures ~4 frames AFTER the console command** — don't move the
  camera in that window or every PNG shows the next camera position (PhotoBooth
  holds 0.5s after each shot for this reason).

## Animation architecture (no engine fork)

Angelscript drives `UVolleyballAnimInstance` (in `Player.as`) by writing `BlueprintReadWrite`
properties every frame. An **Animation Blueprint reparented to `UVolleyballAnimInstance`**
(`/Game/Characters/Mannequin/ABP_VolleyballPlayer`) reads them and blends in its AnimGraph.
`Player.as` loads it by path and falls back to the raw anim instance if absent.

### Bone control — READ THIS BEFORE TOUCHING ARM POSES

- **No bone *setter* is bound in this fork.** `SetBoneRotation` / `SetBoneRotationByName` /
  `SetBoneTransformByName` do NOT exist. Only `Mesh.GetBoneTransform(FName)` is bound (read-only,
  used for arm-vs-ball collision in `GetArmContact` and for `LogArmGeometry`).
- Arm gestures are driven via **Full Body IK**: `HandTargetR/L`, `ElbowPoleR/L`, `HandRotR/L`,
  `CrouchAmount` (world-space effector targets computed per hit type in `PlayerIK.as`).
- **The FBIK effectors interpolate toward their targets with limited speed** (node setting
  in the ABP, not script-controllable): fast-moving targets outrun the arms — a 1.15s serve
  toss left the hand half a metre behind its target, and sprinting players can't converge
  mid-run. Choreograph UNHURRIED (serve = 1.9s), give gestures ~0.3s lead time before
  contact, and verify moving-target behavior in MatchFilmer bursts — the PhotoBooth's
  static poses ALWAYS converge and will hide this class of problem.
- **Poses are choreographed against TIME TO CONTACT, not against "a gesture exists".**
  `Reach()` carries the planner's τ (`AVolleyballPlayer::ReachTau`, ticking down every
  frame); `GestureClock` turns it into monotone 0→1 progress — monotone because τ is a
  re-prediction and a wind-up must never un-wind. `Prep` in `PlayerIK.as` is that clock
  remapped so the PARKED poses (bump platform, set window) are built and still 0.4s
  before contact, while the whip (spike backswing → cocked → strike) lands 0.18s before
  it. Without this the arms snapped into the final contact shape and held it motionless
  for the whole 1.15s gesture lead — "de har inga förberedande rörelser", and 40% more
  hand reversals than filling that second with the movement into the pose.
  The older `ArmRotR/L` + `Transform (Modify) Bone` approach below is SUPERSEDED but the
  bone-space lessons still apply if Modify Bone nodes come back:
- **The Modify Bone nodes are configured: Rotation Mode = `Add to Existing`, Rotation Space =
  `Bone Space`.** This is critical: Pitch/Yaw/Roll are interpreted in the *bone's own* frame,
  NOT component/world space. So "Pitch" does NOT mean "lift in world up" — axes are relative to
  the upperarm bone's local orientation.
- **Confirmed empirically: Pitch ≈ 180 on `upperarm_r` raises the arm straight up.** Pitch is the
  lift axis in this rig's bone space. Calibrate other poses by sweeping Pitch, not by guessing
  Roll/Yaw — pure Roll/Yaw probes produced confusing actor-space results because the measurement
  was in actor space while the rotation is applied in bone space.
- `LogArmGeometry()` logs hand-vs-shoulder offset in **actor space** (fwd=+X, side=+Y, up=+Z).
  Useful, but remember it measures the *result* of a *bone-space* rotation — don't reason about
  the input axes from these numbers directly.
- `bAxisProbe` (set on one player in `GameMode`) cycles probe rotations and logs the outcome —
  the tool for calibrating arm angles. Remove it (and `bDebugAI`/`bDebugHit`) once poses are dialed.

### Mesh / skeleton

- Player mesh: `/Game/Characters/Mannequins/Meshes/SKM_Manny_Simple` (renderable SkeletalMesh).
- **`SK_Mannequin` is the *Skeleton* asset, NOT a mesh.** `Cast<USkeletalMesh>` on it returns
  null → fallback boxes. Load `SKM_Manny_Simple` for the body; the skeleton is referenced by it.
- The full template Manny library (mesh, skeleton, all anim clips incl. Death/dive,
  BS_Idle_Walk_Run, Dash) was copied into `Content/Characters/Mannequins/` (gitignored).
- **Asset version trap:** template assets were saved in UE 5.6 (`++UE5+Release-5.6`); this
  engine is 5.8 (`++UE5+Main`). Older assets fail to load at runtime until re-saved in the
  5.8 editor (Content Browser → folder → Save All upgrades the package format).
- The Anim BP must target this same skeleton or bone driving silently breaks.

## Gameplay

### Rules of play (Erik's) — design constraints, not tuning knobs

1. **You always want the ball in front of you.** Every contact — dig, set, spike —
   happens in front of the chest / hitting shoulder. A ball that gets over and
   behind a player is a lost contact no matter how close they are standing: the
   arm swings from behind the body, the platform faces backwards, the placement
   is noise. Two consequences the code has to honour:
   - Positioning aims a body-depth *behind* the contact point along the ball's
     flight chord and plants there. Standing *on* the contact point puts the ball
     on top of the head and then behind it.
   - A player who is still travelling when the ball arrives will drift past it.
     Arrive early, plant, let the ball come — a moving player is the main way the
     ball ends up behind them.
2. **The whole body goes where the ball goes.** A contact is a weight transfer
   the arms ride on top of, not an arm gesture performed by a statue. Legs,
   hips and platform leave together, in one direction, on the same beat: the
   dig's knees extend on the same seam the platform drives from (`Swing` 0.22,
   after the cushion) and `TriggerHit` gives the body a step's worth of travel
   along the aim (`HitDriveDir`, measured 29-35cm). Arms moving alone is what
   reads as flapping — the eye has nothing to attribute the motion to.
3. **Go, turn, play — in that order, and never overlapped.** A stroke has three
   phases, and each one finishes before the next begins:
   1. **Go.** Travel to the contact spot first, and travel there already facing
      where this ball will be sent — the pin, rule 4. A body that arrives and
      only then discovers it has to turn has arrived late.
   2. **Turn.** Square up to the incoming ball once the feet are planted, not
      while still travelling. This is the only phase that changes facing.
   3. **Play.** Begin the stroke's own movement only once the ball is in the air
      on a flight whose destination is knowable — after the contact that sends
      it here, not before. Starting earlier is committing to a guess, and a
      guess that has to be taken back is exactly the motion that reads as
      flapping.

   The gesture lead (`MB_GestureLead`) buys time for phase 3, not for phases 1
   and 2, and it is measured against the CURRENT flight. If the reach starts
   while the ball is still travelling toward the opponent's contact, the τ it
   was choreographed against belongs to a flight that no longer exists — the
   arms then spend the wind-up committed to the wrong place. "I bagger kopplar
   de alldeles för tidigt."
4. **Every pass goes one metre inside the antenna on the partner's half**, and
   every player expects passes at the pin on their own half — see
   `PartnerPinTarget()` / `MyHalfPinY()` in `AIPlayer.as`. Nobody ball-chases;
   everyone anticipates.

- `Ball.as`: custom Euler physics, procedural sphere mesh. `CheckPlayerCollision()` iterates
  `AVolleyballPlayer`s, gates on `CanContactBall()`, tests arm bones via `GetArmContact()`, and
  lets the player compute the bounce in `OnBallContact()`. Contact model: dig/set with an aim
  are **ballistic placement** (`BallisticVelocity()` solves the arc to the aim spot + 15% of the
  physical reflection); spikes stay reflection + swing impulse. Without ballistic sets the ball
  never reached `SpikeStrikeZ` and the AI could never jump-attack.
- `AIPlayer.as`: state machine. `bIMadeLastTouch` enforces digger ≠ setter ≠ attacker (no double
  contact, no 4th-touch fault). `CanContactBall()` returns `!bIMadeLastTouch`. AI calls `AimAt()`
  (sets `DesiredAim`/`bHasAim`) rather than hitting the ball directly.
- `HumanPlayer.as` extends `AAIPlayer` — AI fallback until gamepad input.

## Git / assets

- **Keep the repo small: no binary assets in git.** `.gitignore` excludes `Content/Characters/`,
  `Content/*.uasset`, `Content/*.umap` (except `CourtLevel.umap`). Mesh/skeleton sources live in
  engine plugins (MoverExamples), not the repo. The Anim BP is authored in-editor and not tracked.

### Commit messages — these become the Play release notes

Write subjects as **Conventional Commits**: `type(scope): subject`. Every push to `main`
publishes to Play Internal Testing, and `scripts/release_notes.py` groups the commit
subjects of that push by type into the "What's new" testers see. The type picks the section:

| type | section | | type | section |
|---|---|---|---|---|
| `feat` | **New** | | `revert` | **Reverted** |
| `fix` | **Fixes** | | `build` `chore` `ci` `docs` `refactor` `style` `test` | **Under the hood** |
| `perf` | **Performance** | | anything unprefixed | **Other** |

- A `!` before the colon (`feat!:`, `fix(ai)!:`) moves the line to a **Breaking** section at the top.
- The type prefix is stripped from gameplay lines (under "Fixes", a leading `fix:` is noise) but
  kept on plumbing ones, so a `ci:` line reads as plumbing rather than as a gameplay change.
- **The subject is player-facing.** Write what changed, not what you touched:
  `fix(court): sand renders as sand instead of a checkerboard`, not `fix: material`.
- Merge commits are skipped, so a merge subject never has to carry meaning.
- Play caps notes at 500 chars; the script trims lowest-priority sections first and appends
  "…and N more" rather than silently dropping commits. Preview any range locally:

      git log --no-merges --format='%s' <from>..<to> | python3 scripts/release_notes.py
