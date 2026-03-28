# Prismata Fabrication Terminal — User Guide

A web-based tool for generating 3D models from Prismata unit sprites using AI (Hunyuan3D v2.0). Select a unit, tweak settings, and fabricate a 3D model in ~2 minutes.

## Getting Started

### 1. Start a GPU Instance (via Discord)

In the **#prismata-ops** Discord channel:

```
!start        — Launch a spot instance (~$0.40-0.80/hr, can be interrupted)
!start od     — Launch an on-demand instance (~$1.01/hr, reliable)
```

The bot will post updates as the instance starts up (~3-5 minutes):
1. "Instance launching..."
2. "Instance running, waiting for tunnel..."
3. **"Ready!"** with two URLs:
   - **ComfyUI** — the raw ComfyUI interface (for advanced users)
   - **Fabrication Terminal** — the Prismata-specific UI (use this one)

Click the **Fabrication Terminal** link to open it in your browser.

### 2. Other Discord Commands

```
!status       — Show running instances, costs, and access URLs
!stop         — Shut down all running instances
```

**Auto-shutdown:** Instances automatically terminate after 10 minutes of idle time to save costs.

### 3. Sharing Access

The Fabrication Terminal URL is a public Cloudflare tunnel — anyone with the link can use it. Just share the URL from the Discord bot's "Ready!" message. The URL changes each time a new instance starts.

## Using the Fabrication Terminal

### Basic Workflow

1. **Select a unit** from the dropdown (279 units available)
2. **Choose a skin** (Regular, Legendary, etc.)
3. Preview the 2D sprite on the left
4. Click **Fabricate Unit**
5. Watch progress in the status bar (~1-2 min)
6. The 3D model appears in the preview — rotate it with your mouse

### Generation Settings

| Setting | Default | What It Does |
|---------|---------|--------------|
| **Steps** | 20 | Diffusion steps. More = better quality, slower. 15-20 for speed, 30-50 for quality. |
| **Guidance Scale** | 5.5 | How closely the model follows the input image. 3-4 = creative, 5.5 = balanced, 6-8 = faithful. |
| **Octree Resolution** | 256 | Mesh detail. 128 = fast/low, 256 = standard, 384 = high detail. |
| **Seed** | 42 | Random seed. Same seed + same settings = same output. Click the refresh button for a random seed. |
| **Best / Fast toggle** | Best | Fast mode: steps=15, octree=128, cleanup=off (~30s). Best: steps=20, octree=256, cleanup=on (~2 min). |

### Advanced Settings

Click **Advanced Settings** to expand:

- **Model Variant** — v2.0 (best quality, ~16GB VRAM) or v2-mini Turbo (fast preview, ~5GB)
- **Attention Mechanism** — SDPA (default) or Flash Attention 2
- **Num Chunks** — VAE decoding chunks (higher = faster, more VRAM)
- **Postprocess** — Mesh cleanup (recommended)
- **Target Vertices** — Vertex count for cleanup
- **Texture** — Enable/disable texture baking (adds ~1 min)
- **Export Format** — GLB (default), OBJ, PLY, STL

### Expert Settings

Click **Expert Only** to expand (red border = here be dragons):

- **White Background** — Composite sprite onto white before generation
- **VAE Decode** parameters — Fine-tune marching cubes
- **Performance** — Chunk sizes for diffusion

Use the **reset buttons** (circular arrows) to restore defaults for each section.

## Favorites

### Starring Models

After generating a model, it appears in the **Session History** strip below the 3D preview. Each history card has:

- **Star** (top-right corner) — Click to favorite. Saves to S3 so it persists across sessions.
- **Thumbs-down** (bottom-right corner) — Mark as a bad generation.

### Favorites Badge

The **star badge** in the top-right header shows your total favorite count.

- **Hover** the badge to see a dropdown of your most recent favorites (sprite thumbnails)
- **Click a favorite** in the dropdown to load that exact model into the preview and select its unit/skin
- **Click the badge itself** to open the full favorites overlay with all favorited models

### Session History

The horizontal strip below the preview shows all models generated in the current session. Click any card to reload that model. Session history resets when you refresh the page — but favorites persist in S3.

## Batch Mode

Click **Batch Mode** below the Fabricate button to generate models for multiple units automatically.

1. A checklist of all units/skins appears
2. **Filter** by name, **Select All / None**
3. Units with existing S3 models are grayed out
4. Check **Skip if exists** to skip units that already have models in S3
5. Click **Start Batch** — runs through each unit sequentially
6. Use **Stop** to halt the batch

## Tips

- **Try different seeds** — Same unit with different seeds produces different shapes. Generate a few and star the best one.
- **Fast mode for exploration** — Use Fast toggle to quickly iterate, then switch to Best for your final generation.
- **Texture adds time** — Disable texture in Advanced Settings for faster shape-only previews.
- **Download your models** — Click **Download GLB** to save the current model. GLB files work in Blender, Godot, and most 3D tools.
- **Models sync to S3** — Generated models are automatically uploaded to S3 within ~30 seconds. You don't need to manually save them.

## Costs

| Resource | Cost |
|----------|------|
| Spot instance (g5.xlarge) | ~$0.40-0.80/hr |
| On-demand instance | ~$1.01/hr |
| S3 storage | ~$0.02/month (tiny) |
| Auto-shutdown | After 10 min idle |

A typical session generating 5-10 models costs about $0.50-1.00.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| "ComfyUI Offline" | Instance is still starting up. Wait 1-2 min and refresh. |
| Fabricate button disabled | Select a unit and skin first. |
| Model looks boxy/flat | Some sprites produce boxy shapes. Try a different seed or guidance scale. |
| "No model found" error | The model may not have finished uploading to S3. Wait 30 seconds and retry. |
| Instance disappeared | Spot instances can be interrupted by AWS. Use `!start od` for on-demand. |
| URL stopped working | Instance was auto-shutdown after 10 min idle. Use `!start` again. |
