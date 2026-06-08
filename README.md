# Beach Volleyball — Unreal Engine 5 + AngelScript

A beach volleyball game built entirely with AngelScript and procedural mesh generation. No imported 3D models — all geometry is created at runtime.

## Features

- **Rally scoring** — sets 1 & 2 to 21 points, deciding set to 15 (2-point lead required)
- **Full physics** — Euler integration with gravity, air drag, floor bounce, net collision
- **Procedural geometry** — sphere (ball), flat quads (sand/net), lines, cylinders (posts)
- **AI opponent** — forward-integration trajectory prediction, adjustable difficulty (0–1)
- **HUD** — live score, set counter, game phase text, minimap
- **Side camera** — smooth ball-following with configurable weights

## Controls

| Key | Action |
|-----|--------|
| W/A/S/D | Move |
| Space | Jump |
| E | Pass (bump) |
| Shift | Set |
| F | Spike |
| Escape | Pause |

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
  Court.as                 — sand, net, boundary lines, posts (all procedural)
  GameMode.as              — spawn, serve flow, point/set/match logic, restart
  HUD.as                   — Canvas HUD: score, phase, minimap
  Camera.as                — side-view camera with soft ball-following
  CourtLevel.as            — level script: directional light, sky atmosphere, fog
```

## Setup

1. Install **Unreal Engine 5.3+**
2. Install the **AngelScript for UE5** plugin (https://angelscript.hazelight.se/)
3. Open `BeachVolleyball.uproject`
4. Cook and play — the `CourtLevel` default map runs the full game

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
