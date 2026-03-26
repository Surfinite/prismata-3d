# prismata-3d — Godot 4 Replay Viewer

## What This Is

A Godot 4.x project that renders Prismata game replays as a 3D battlefield. Cards are rendered as layered Sprite3D nodes (background texture + card art + status icons). The viewer loads pre-processed snapshot JSON and steps through game states.

## Project Structure

```
main.gd / main.tscn     — Entry point, wires replay controller → battlefield + HUD
battlefield/             — Card rendering (unit_node.gd), layout, visual state
camera/                  — OrbitCamera: top-down (ortho) ↔ 3D orbit (T key toggle)
ui/                      — ReplayHUD (scrubber, controls), BuyPanel (two-column SWF layout)
replay/                  — ReplayController: playback state machine, step/play/jump
providers/               — Data sources (FileProvider loads JSON, BaseProvider interface)
visual/                  — VisualHooks (buy/kill effects), VisualContext, CardVisualState
assets/                  — Card sprites (143 PNGs), backgrounds, icons, overlays, effects
data/                    — Replay snapshot JSON (current_replay.json)
```

## How to Run

1. Open in Godot 4.x (Import Project → select this folder)
2. Press F5 (Play) — loads `data/current_replay.json` automatically
3. Controls:
   - **Arrow keys / ▶ button**: Step through turns
   - **Space**: Play/pause
   - **Scroll wheel**: Zoom
   - **Right-drag / middle-drag**: Pan
   - **T**: Toggle top-down ↔ 3D orbit mode
   - **Left-drag** (in 3D mode): Orbit around the board
   - **Home / End**: Jump to start / end of replay

## Architecture

**Data flow**: Replay JSON → FileProvider → ReplayController → emits `snapshot_changed` → Battlefield reconciles unit nodes + HUD updates.

**Card rendering** (`unit_node.gd`): Each unit is a Node3D with layered Sprite3D children:
- Layer 0: Background texture (blue/red, based on owner + status)
- Layer 1: Card art sprite
- Layer 2: Status icons (attack sword, defense shield, variable icons)
- Layer 3: Labels (name, numbers, build timer)

**Visual state** (`card_visual_state.gd`): Pure decision tree mapping unit data → which background, which icons to show, what numbers to display.

**Layout**: Units are positioned by row (front/middle/back) using SWF-derived constants. Piles of same-type units overlap horizontally.

## Generating Replay Data

Snapshots are generated from raw replay JSON using the PrismataAI repo:
```bash
# In the PrismataAI repo:
node tools/replay_to_snapshots.js <replay.json.gz> [output.json]
```

## Visual Ground Truth

The **SWF client** (original Prismata Flash app) is the visual ground truth, not the PixiJS browser viewer. When positioning icons or choosing colors, match the SWF first. The PixiJS viewer is a useful code reference but has some divergences.

## Collaboration

- **Surfinite**: Replay pipeline, card rendering, layout engine, data flow
- **homander (Flopflop)**: 3D models, skybox, battlefield environment, visual polish

## Key Constraints

- Card positions use world units where 82px (one card width in SWF) = 1.0 world unit
- Camera top-down is orthographic; 3D mode is perspective with 75° FOV
- P0 (blue) = bottom of screen, P1 (red) = top — matches SWF convention
- All 143 card sprites are in `assets/card_sprites/` as `snake_case.png`
- Background textures are in `assets/backgrounds/` — named by visual state (busy, block, dead, etc.)
