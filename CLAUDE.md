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

## For homander

Welcome! Here's context to help you and Claude work effectively:

### Your role
You own **3D models, visual design, and battlefield aesthetics**. Your work lives in `visual/` and `assets/`. The replay engine, data pipeline, and card rendering are Surfinite's domain — ask before modifying files outside your areas.

### Vision
The long-term goal is a full 3D battlefield viewer — units as 3D models on terrain, resource tanks (gold/green/red/blue), RTS-style camera, cinematic breach animations. Start with replacing 2D sprites with 3D models one unit at a time.

### What Prismata units look like
- Browse unit art at: `assets/card_sprites/` (143 PNGs of every unit)
- Unit data (names, stats, costs): `c:\libraries\PrismataAI\bin\asset\config\cardLibrary.jso`
- The Prismata wiki has lore and high-res art: https://prismata.fandom.com/wiki/
- Start with **Drone** — it's the most common unit (every game has 6+ of them)

### Working with 3D models
- Godot 4 imports `.glb` (preferred), `.gltf`, and `.obj` files natively — just drop them in `assets/`
- Blender exports to `.glb` via File → Export → glTF 2.0
- For STL files (like Blossom_Manifold.stl): import into Blender first, then export as `.glb`
- Keep models low-poly — there can be 30+ units on screen at once

### Superpowers (Claude Code skills)
This project uses **superpowers** — special skills that make Claude much more effective. Key ones:
- **`/brainstorming`** — use before any creative work (designing models, planning visuals). Explores intent before jumping to code.
- **`/feature-dev`** — guided feature development with codebase understanding
- **`/commit`** — commit your work cleanly
- **`/status`** — see project status

Type `/` in Claude Code to see all available skills.

### Related docs (in the PrismataAI repo at `c:\libraries\PrismataAI\`)
- Godot viewer spec: `docs/superpowers/specs/2026-03-26-godot-3d-battlefield-viewer-design.md`
- Visual parity plan: `docs/superpowers/plans/2026-03-26-godot-visual-parity-phase1.md`
- Unit reference: `docs/wiki/PRISMATA_REFERENCE.md`
- Strategy guide (game knowledge): `docs/prismata-strategy-guide.md`

### Creating 3D models from card art

You can use AI to generate 3D models from the 2D card sprites. Several approaches:

**AI image-to-3D tools (easiest — upload card art, get a model back):**
- [Tripo](https://www.tripo3d.ai) — free, outputs GLB. Upload a card sprite, get a 3D model in seconds.
- [Meshy](https://www.meshy.ai) — has a dedicated low-poly game mode and Godot export. Free tier limited.
- [AI3DGen](https://www.ai3dgen.com/) — no signup needed, outputs OBJ/STL/GLB.
- [3D AI Studio](https://www.3daistudio.com/UseCases/Godot) — specifically targets Godot, outputs GLB with PBR materials.

**Claude + Blender MCP (most powerful — Claude controls Blender directly):**
- Install [Blender MCP](https://github.com/ahujasid/blender-mcp) addon in Blender
- Claude can then create, modify, texture 3D models via natural language
- Guide: [How to Connect Claude AI to Blender](https://medium.com/@gizmo.codes/how-to-connect-claude-ai-to-blender-a-practical-guide-for-3d-artists-b96c141cd97c)
- This lets you say things like "make a small robot drone with propellers" and Claude builds it in Blender

**Manual Blender workflow:**
- Import card sprite as reference image in Blender
- Model by hand or use Blender's sculpting tools
- Export as `.glb` (File → Export → glTF 2.0)
- Drop the `.glb` into `assets/models/` — Godot imports it automatically

**Tips:**
- Start with Drone — simplest, most common, instant visual impact
- AI-generated models often need cleanup in Blender (reduce poly count, fix normals)
- Target <5000 triangles per model for good performance with 30+ units on screen
- Card sprites at `assets/card_sprites/drone.png` etc. make good reference images for AI tools

### Quick start tasks
1. Open the Godot project, press F5, see the 2D replay viewer working
2. Try generating a 3D Drone model — upload `assets/card_sprites/drone.png` to [Tripo](https://www.tripo3d.ai) or [Meshy](https://www.meshy.ai)
3. Export as `.glb`, put it in `assets/models/`
4. Ask Claude to help you write a script that replaces the Drone sprite with your 3D model
