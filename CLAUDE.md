# AngelBeach — beach volleyball (UE5.7, Hazelight Angelscript fork)

A beach volleyball game written almost entirely in Angelscript (`Script/*.as`).
Players are `APawn`s with a Manny skeletal mesh; a custom physics ball bounces off
their arm bones; AI plays structured volleyball (receive → set → attack).

## Build / reload workflow

- **Logic-only changes** (edit a method body): **Soft Reload** (Ctrl+Shift+F11) hot-reloads.
- **New member variable / UPROPERTY / changed spawn layout**: requires a **Full Reload**
  (Ctrl+Alt+F11 or restart editor) — soft reload will NOT pick it up.
- Logs: `Saved/Logs/BeachVolleyball.log`. Angelscript `Log()` lines are prefixed `Angelscript:`.

## Animation architecture (no engine fork)

Angelscript drives `UVolleyballAnimInstance` (in `Player.as`) by writing `BlueprintReadWrite`
properties every frame. An **Animation Blueprint reparented to `UVolleyballAnimInstance`**
(`/Game/Characters/Mannequin/ABP_VolleyballPlayer`) reads them and blends in its AnimGraph.
`Player.as` loads it by path and falls back to the raw anim instance if absent.

### Bone control — READ THIS BEFORE TOUCHING ARM POSES

- **No bone *setter* is bound in this fork.** `SetBoneRotation` / `SetBoneRotationByName` /
  `SetBoneTransformByName` do NOT exist. Only `Mesh.GetBoneTransform(FName)` is bound (read-only,
  used for arm-vs-ball collision in `GetArmContact` and for `LogArmGeometry`).
- Arm rotations are therefore driven via `ArmRotR` / `ArmRotL` (FRotator) properties fed into
  **`Transform (Modify) Bone`** nodes in the AnimGraph (one for `upperarm_r`, one for `upperarm_l`).
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
  engine is 5.7 (`++UE5+Main`). 5.6 assets fail to load at runtime until re-saved in the 5.7
  editor (Content Browser → folder → Save All upgrades the package format).
- The Anim BP must target this same skeleton or bone driving silently breaks.

## Gameplay

- `Ball.as`: custom Euler physics, procedural sphere mesh. `CheckPlayerCollision()` iterates
  `AVolleyballPlayer`s, gates on `CanContactBall()`, tests arm bones via `GetArmContact()`, and
  lets the player compute the bounce in `OnBallContact()` (reflection + swing impulse — no teleport).
- `AIPlayer.as`: state machine. `bIMadeLastTouch` enforces digger ≠ setter ≠ attacker (no double
  contact, no 4th-touch fault). `CanContactBall()` returns `!bIMadeLastTouch`. AI calls `AimAt()`
  (sets `DesiredAim`/`bHasAim`) rather than hitting the ball directly.
- `HumanPlayer.as` extends `AAIPlayer` — AI fallback until gamepad input.

## Git / assets

- **Keep the repo small: no binary assets in git.** `.gitignore` excludes `Content/Characters/`,
  `Content/*.uasset`, `Content/*.umap` (except `CourtLevel.umap`). Mesh/skeleton sources live in
  engine plugins (MoverExamples), not the repo. The Anim BP is authored in-editor and not tracked.
