# Batch 3D Model Generation Pipeline

**Date**: 2026-03-27
**Author**: Surfinite + Claude
**Status**: Approved

## Purpose

Generate "starting point" 3D models (GLB) for all ~143 Prismata units plus skin variants, using AI image-to-3D generation. Models are rough concept meshes for iteration, not production-ready assets. A Discord-controlled AWS Spot instance runs Hunyuan3D with a web UI so homander can test individual units, tweak settings, and trigger batch runs.

## Architecture

Three components:

```
┌─────────────┐     ┌──────────────────────────────┐     ┌─────────┐
│ Discord Bot │────>│  AWS EC2 Spot (g5.xlarge)    │────>│   S3    │
│ (ladder     │<────│  - Hunyuan3D 2.0             │     │  bucket │
│  server)    │     │  - ComfyUI + custom frontend │     │         │
└─────────────┘     │  - Idle watchdog             │     └────┬────┘
                    │  - Interruption monitor      │          │
                    └──────────────────────────────┘     aws s3 sync
                         ▲                                    │
                         │ browser                            ▼
                    ┌────┴────┐                     ┌─────────────────┐
                    │homander │                     │ assets/models/  │
                    └─────────┘                     │ (local)         │
                                                    └─────────────────┘
```

### Component 1: AWS EC2 Spot Instance

- **Instance**: g5.xlarge (NVIDIA A10G, 24GB VRAM)
- **Launch method**: `run-instances` with `--instance-market-options` (NOT legacy `RequestSpotInstances`)
- **AMI**: Custom, pre-baked with Hunyuan3D 2.0, ComfyUI, Python deps, unit data (sprites + descriptions)
- **On-demand fallback**: If no spot capacity, offer to launch on-demand with an estimated cost warning to Discord
- **Multi-region** (Phase 2): All candidate spot regions must have a copied AMI and region-local supporting infrastructure (security groups, EventBridge rules, Lambda). Phase 1 uses a single region.
- **Startup time**: ~2-3 minutes from API call to UI ready

**Model variants available** (selectable in UI):
| Variant | VRAM | Use case |
|---------|------|----------|
| Hunyuan3D-2mini | ~5GB | Fast iteration, quick previews |
| Hunyuan3D-2.0 | ~16GB | Normal quality, final generation |
| Hunyuan3D-2mv | ~16GB | Multi-view input (front/side/back) |

Note: Hunyuan3D 2.1 requires ~29GB VRAM, exceeding g5.xlarge capacity. If later benchmarking shows the selected 2.1 workflow exceeds g5.xlarge, upgrade to a larger GPU instance after measurement. Note that g5.2xlarge is still a single A10G; multi-GPU G5 starts at g5.12xlarge. Alternatively, consider p-series (A100) instances.

### Component 2: Discord Bot

Runs as a Python process on the ladder site server (always-on, alongside existing services). Lightweight — ~50MB RAM, negligible CPU.

**Commands:**
- `!start` — request spot instance, post status updates
- `!stop` — shut down instance immediately
- `!status` — running?, URL, uptime, estimated cost so far

**Notifications (bot posts to channel):**
- "Starting up (~2-3 min)..."
- "Ready! Open https://{url}" (or Tailscale/tunnel URL)
- "No spot capacity in us-east-1, trying us-west-2..."
- "No spot capacity available in any region. Launch on-demand? (~$1.00/hr) React with ✅ to confirm"
- "⚠️ Spot instance being reclaimed by AWS! Saving work to S3..."
- "Shutting down after 10 min idle"

**Interruption handling:**
- EventBridge rule triggers Lambda on spot interruption event → posts to Discord via webhook
- Instance-side: IMDSv2 metadata polling every 5s as backup → saves in-progress job state to S3
- Phase 2: Also monitor EC2 rebalance recommendation signal (earlier warning when instance is at elevated interruption risk) → post advisory to Discord

### Component 3: S3 Storage

**Bucket structure:**
```
s3://prismata-3d-models/
  models/{unit_name}/{skin_name}/{job_id}/
    model.glb
    thumb.png
    metadata.json
    input.png
    custom_uploads/        (if any user-uploaded images)
  latest/{unit_name}/{skin_name}/model.glb    (promoted "best" version)
  latest/{unit_name}/{skin_name}/thumb.png
```

Sync approved results to local: `aws s3 sync s3://prismata-3d-models/latest/ assets/models/`

Local `assets/models/` mirrors the `latest/` structure: `assets/models/{unit_name}/{skin_name}/model.glb`.

## Web UI

ComfyUI base with a thin HTML/JS wrapper around ComfyUI workflow/API endpoints (not a separate SPA). Homander accesses via browser.

### Controls

**Unit Selection:**
- Unit dropdown — all 143 units (populated from card sprite filenames)
- Skin dropdown — available skins for selected unit (from `.skin` files in `newUnitArt/`)
- Image preview — shows the selected 300x300 sprite

**Text Description:**
- Editable text field next to the image preview
- Pre-populated with wiki/card library description for the selected unit
- User can edit freely or clear entirely
- Sent alongside the image to Hunyuan3D as a text prompt

**Custom Image Upload:**
- Upload area (drag-and-drop or file picker), supports PNG/JPG/WebP
- Max 2048x2048, max 10MB per image
- Multiple images supported

**Upload Modes** (selectable):
| Mode | Behavior |
|------|----------|
| Prismata only | Selected unit sprite + text description |
| Custom only | Uploaded image(s) + optional text, no Prismata sprite |
| Hybrid | Prismata sprite as primary input, uploaded image as style reference |
| Multi-view | Multiple uploaded images as different viewpoints (use with 2mv model) |

**Generation Settings:**
- Model variant: 2mini / 2.0 / 2mv (dropdown)
- Inference steps (default: 20)
- Guidance scale (default: 5.5)
- Octree resolution (default: 256)
- Seed (editable, randomize button)
- Background removal toggle (for custom uploads)

**Preview of actual input** — shows the exact image(s) being fed to generation after any preprocessing.

**Actions:**
- Generate — single unit with current settings
- Batch generate — with explicit scope selector:

**Batch scopes:**
| Scope | What it queues |
|-------|---------------|
| All base units | 143 jobs, one per unit using Regular skin |
| All skins for selected unit | N jobs, one per skin variant of the current unit |
| All units × all skins | Full matrix (~627 jobs) |

- `skip-if-exists` checkbox (default: on) — skips units/skins that already have output in S3
- Animated skin variants excluded from batch in v1 (single best frame is used instead)

### Result Viewer

- 3D model preview (interactive rotate/zoom)
- Thumbnail render
- Download GLB button
- "Use these settings for batch" button

## Input Preprocessing

Runs as a preprocessing step on the EC2 instance before generation.

**Phase 1 (basic):**
1. **Verify transparency** — Prismata sprites are RGBA PNGs; confirm alpha channel is clean
2. **Tight crop** — remove excess transparent padding, center the subject
3. **Normalize size** — resize to canonical input size expected by the model
4. **Background removal** — for custom uploads, basic alpha matting

**Phase 3 (advanced):**
5. **Upscale** (experimental) — 300x300 → 512x512 or 1024x1024 using a lightweight upscaler if quality improves
6. **Stronger matting** — improved background removal for complex custom uploads
7. **Hybrid composition** — smarter merging of Prismata sprite + custom art in hybrid mode

## Job Queue & State Model

Every generation (single or batch) creates a **job** with a unique ID.

**Job states:**
```
queued → running → completed
                 → failed → retry (up to 3x)
         cancelled
```

**Queue behavior:**
- Jobs processed FIFO
- Single concurrent generation (GPU is the bottleneck)
- Batch mode queues one job per unit/skin combination (see batch scopes in Web UI section)
- Cancel / pause batch from UI
- Resume after spot interruption: incomplete jobs re-queued on next instance start

**State persistence:** Job queue state saved to S3 every 30s and on interruption. On instance startup, check for incomplete queue and offer to resume.

## Output Specification

### Per-job output

**model.glb:**
- GLB format with embedded textures
- Target: concept mesh quality, not production-ready
- No specific polycount target for v1 (Hunyuan3D output as-is)

**thumb.png:**
- 512x512 rendered thumbnail
- Generated via trimesh/pyrender headless on the EC2 instance
- 3/4 view angle, neutral lighting
- Transparent background

**metadata.json:**
```json
{
  "job_id": "j_20260327_143022_aegis",
  "unit": "aegis",
  "skin": "Regular",
  "prompt": "Aegis - A large defensive structure...",
  "seed": 42,
  "model_variant": "hunyuan3d-2.0",
  "steps": 20,
  "guidance_scale": 5.5,
  "octree_resolution": 256,
  "input_image_hash": "sha256:abc123...",
  "custom_upload_hashes": [],
  "upload_mode": "prismata_only",
  "generation_time_seconds": 95,
  "ami_version": "prismata-3d-gen-v1",
  "timestamp": "2026-03-27T14:30:22Z",
  "vertex_count": 12847,
  "face_count": 25102
}
```

### Post-processing (Phase 2)

Not in v1, but defined here for future:
- Target polycount: <5000 triangles (decimation via Blender headless or meshlab)
- Scale normalization: largest dimension = 1.0 Blender unit
- Pivot/origin: center bottom
- Facing direction: front-facing -Y (Godot convention)
- Texture size: 1024x1024 max
- Mesh cleanup: remove non-manifold geometry, fix normals
- Naming convention: `{unit_name}_{skin}_{version}.glb`

## Idle Shutdown

A watchdog process on the instance monitors activity:
- Check ComfyUI WebSocket connections (active clients?)
- Check job queue (any queued/running jobs?)
- Check last API request timestamp

If ALL are idle for 10 minutes:
1. Post "Shutting down after 10 min idle" to Discord
2. Wait 60 seconds (in case someone reacts)
3. Sync any unsaved outputs to S3
4. `sudo shutdown -h now`

Does NOT shut down if a batch job is running, even if no one is connected to the UI.

## Security

**Phase 1 (recommended):**
- Cloudflare Tunnel or Tailscale for ComfyUI access — no public IP, no raw port exposure
- Bot provides access URL on `!start` (tunnel URL or Tailscale IP)
- SSM Session Manager for admin access (preferred over SSH with key pairs)
- S3 bucket private, accessed via AWS CLI with credentials
- EC2 security group: no public ingress needed if using tunnel

**Fallback (if tunnel setup is blocked):**
- ComfyUI behind nginx reverse proxy with basic auth
- EC2 security group: port 443 open to specific IPs only (homander + Surfinite)
- SSH access via key pair

## Data Sources

**Card sprites** (143 units):
- `assets/card_sprites/*.png` — 300x300 RGBA PNGs
- Also at `C:\libraries\PrismataAI\bin\asset\images\cards\` (same images, capitalized names)

**Skin variants** (627 skins across all units):
- `C:\libraries\Prismata\newUnitArt\*.skin` — batch archive format containing buySD/HD, infoSD/HD, instSD/HD PNGs
- Maximum resolution: 300x300 per frame
- Extractor needed: simple archive format (4-byte file count, then 64-byte name + 4-byte size per entry, then concatenated data)

**Animated skins** (32 animated variants, 16 units):
- `C:\libraries\Prismata\animatedUnit\*_large.batch` — sprite sheets (e.g. 1812x1208) with XML atlas metadata
- Individual frames are 300x300
- Mostly subtle background motion; single best frame is sufficient for 3D generation

**Text descriptions:**
- Card library: `C:\libraries\PrismataAI\bin\asset\config\cardLibrary.jso`
- Wiki reference: `C:\libraries\PrismataAI\docs\wiki\PRISMATA_REFERENCE.md`
- Prismata wiki: https://prismata.fandom.com/wiki/

**Batch file format** (`.skin` and `.batch`):
```
[4 bytes] num_files (uint32 LE)
[repeat num_files]:
  [64 bytes] filename (ASCII, space-padded)
  [4 bytes]  file_size (uint32 LE)
[concatenated file data in order]
```

## Implementation Phases

### Phase 0: Asset Preparation (one-time, runs locally)
- Extract all `.skin` files → individual PNGs per unit/skin
- Extract best frame from animated `.batch` files
- Parse `cardLibrary.jso` and wiki reference for text descriptions
- Build portable manifest:
  ```
  tools/prismata_asset_prep/
    extract_skins.py
    extract_animated_frames.py
    build_manifest.py

  generated/prismata_3d_input/
    units/{unit}/{skin}.png
    manifest.json         (unit → skins → file paths)
    descriptions.json     (unit → wiki text description)
  ```
- This output is copied into the AMI build context and S3, making the runtime system portable (no Windows path dependencies)

### Phase 1: Core Pipeline (MVP)
- AMI build script (Hunyuan3D 2.0 + ComfyUI + deps + prepared asset data)
- Discord bot: `!start`, `!stop`, `!status`
- Spot instance launch/stop (single region) with on-demand fallback
- ComfyUI workflow: single unit generation (image + text → GLB)
- Unit selector with sprite preview
- Text description field (pre-populated from manifest descriptions)
- Seed field (editable + randomize button)
- Basic input preprocessing (verify alpha, tight crop, normalize size)
- S3 upload of outputs with metadata.json
- Idle auto-shutdown
- Cloudflare Tunnel or Tailscale for secure access (preferred over raw port exposure)
- SSM Session Manager for admin access (preferred over SSH key pair)

### Phase 2: Batch & Polish
- Batch mode with explicit scope selector (base units / all skins / full matrix)
- Job queue with state persistence and resume-after-interruption
- Skin selector (from prepared manifest)
- Custom image upload with mode selector (Prismata only / Custom only / Hybrid / Multi-view)
- Model variant selector (2mini / 2.0 / 2mv)
- Thumbnail renderer (trimesh/pyrender headless)
- Output versioning in S3 (unit/skin/job_id structure)
- Spot interruption → Discord notification via EventBridge + Lambda
- Multi-region spot fallback (requires AMI copy + per-region infra)
- Rebalance recommendation signal monitoring (early warning before interruption)

### Phase 3: Production Quality
- Post-processing pipeline (decimation, normalization, cleanup)
- Advanced input preprocessing (upscale experiments, stronger matting, hybrid composition)
- Gallery view of all generated models
- Promote/approve workflow for syncing to assets/models/

## Cost Estimate

All figures are estimates. Actual costs vary with spot pricing, retries, and scope.

| Item | Cost | Assumes |
|------|------|---------|
| g5.xlarge spot (~$0.40/hr) | ~$2-5 per batch run | 143 base units, Regular skin only, no retries |
| Full skin matrix (~627 units×skins) | ~$10-25 per batch run | spot pricing, no retries |
| On-demand fallback (~$1.00/hr) | ~$5-12 per batch run | if spot unavailable |
| S3 storage (~1GB of GLBs) | ~$0.02/mo | |
| EventBridge + Lambda | ~$0 (free tier) | |
| Discord bot on ladder server | $0 (existing infra) | |
| AMI storage (EBS snapshot) | ~$1-2/mo | |
| Cloudflare Tunnel | $0 (free tier) | |
| **Total for initial base-unit batch** | **~$5-10** | |

`!status` reports estimated cost based on instance uptime × hourly rate.

## Resolved Questions

1. **Discord channel**: Use existing `Prismata-ops` channel (in the ladder repo Discord)
2. **Concurrent instances**: Max 2 instances at once (one per user). Each instance has its own independent queue — no shared queueing in v1.
3. **AWS region**: us-east-1 (co-located with existing `prismata-live` and `prismata-data` instances in us-east-1c)
4. **Bot deployment**: Runs on `prismata-data` (t4g.micro, ARM/Graviton, on-demand, Linux). Deployed via SSH alongside existing `headless_multi.py` spectator service. Python process managed by systemd.
5. **Access method**: Cloudflare Tunnel (zero-install for homander, no public IP needed on EC2)
6. **Sprite quality**: All 143 sprites are clean RGBA PNGs with proper alpha. Two sizes: 103 at 300x300 and 40 at 128x128. No manual cleanup needed — preprocessing normalizes to consistent size.
