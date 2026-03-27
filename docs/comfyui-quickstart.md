# ComfyUI + Hunyuan3D Quick Start Guide

A practical guide for generating 3D models from Prismata unit sprites.

## Getting Started

### 1. Launch the GPU Instance

In Discord `#prismata-ops`, type:
```
!start
```

The bot will reply with status updates:
- "Starting up (~2-3 min)..."
- "Ready! Open https://random-words.trycloudflare.com"

Click the tunnel URL to open ComfyUI in your browser.

### 2. The ComfyUI Interface

ComfyUI uses a **node-based workflow** (like Blender's shader nodes). You'll see a canvas with connected boxes (nodes). Each node does one thing — load an image, run the AI model, save the output. Data flows left to right through the connections.

**Key areas:**
- **Canvas** (center): The node graph. Right-click to add nodes, drag to pan, scroll to zoom.
- **Queue Prompt** button (right sidebar or top): Starts generation.
- **Queue** panel: Shows running/pending jobs.
- **Manager** button: Node package management (you shouldn't need this).

### 3. Load the Hunyuan3D Workflow

The example workflows are pre-installed on the instance.

1. Click **Load** (or drag a `.json` file onto the canvas)
2. Navigate to: `custom_nodes/ComfyUI-Hunyuan3DWrapper/example_workflows/`
3. Load `hy3d_example_01.json` — this is the basic image-to-3D pipeline

You'll see a graph with nodes like:
- **Load Image** — where you set the input sprite
- **Hunyuan3D Sampler** — the AI model that generates the 3D shape
- **Hunyuan3D Paint** — adds texture/color to the mesh
- **Save 3D** — exports the GLB file

### 4. Upload a Prismata Sprite

The Prismata sprites are pre-loaded on the instance at `/opt/prismata-3d/assets/units/`.

**Option A — Use pre-loaded sprites:**
1. Click on the **Load Image** node
2. In the image selector dropdown, look for `prismata-assets/units/{unit_name}/Regular.png`
3. The sprites are symlinked into ComfyUI's input folder

**Option B — Upload your own:**
1. Click on the **Load Image** node
2. Click **Upload** or drag an image onto it
3. Supports PNG, JPG, WebP (max 2048x2048)

### 5. Adjust Generation Settings

The key parameters (found on the **Hunyuan3D Sampler** node):

| Parameter | Default | What it does |
|-----------|---------|-------------|
| **steps** | 20 | More steps = better quality but slower. Try 15-30. |
| **guidance_scale** | 5.5 | How closely it follows the input image. Higher = more faithful. Try 3-8. |
| **seed** | random | Fixed seed = reproducible results. Change to try variations. |
| **octree_resolution** | 256 | Mesh detail level. 256 is good default, 384 for more detail. |

**Model variants** (if multiple are available in the workflow):
| Variant | Speed | Quality | Use for |
|---------|-------|---------|---------|
| Hunyuan3D-DiT-v2-mini-Turbo | ~10s | Good | Quick previews, testing settings |
| Hunyuan3D-DiT-v2-0-Turbo | ~15s | Better | Fast iteration with good quality |
| Hunyuan3D-DiT-v2-0 | ~45s | Best | Final generation |

### 6. Generate!

1. Click **Queue Prompt** (or press Ctrl+Enter)
2. Watch the progress bar on each node as it processes
3. The **Hunyuan3D Sampler** node takes the longest (10-60s depending on model variant)
4. The **Paint** node adds texture (~15-30s)
5. When complete, the **Save 3D** node shows the output path

### 7. Download Your Model

The generated GLB file is saved to the ComfyUI output directory.

**From the UI:**
- Click on the **Save 3D** node output
- Right-click the output → Save/Download

**From the file browser:**
- The output directory is accessible at: `https://{tunnel-url}/view?filename={name}&type=output`

## Tips for Prismata Units

### Best Results
- **Clean alpha matters**: The sprites already have clean transparency — no preprocessing needed.
- **Start with Drone**: It's simple geometry (small robot), generates well, and you'll have lots in every game to compare against.
- **Try multiple seeds**: Same sprite + different seed = very different 3D interpretations. Generate 3-5 and pick the best.
- **Lower guidance for organic units**: Units like Gaussite Symbiote or Zemora benefit from lower guidance (3-4) to let the model be creative with the 3D shape.
- **Higher guidance for mechanical units**: Steelsplitter, Drakesmith, etc. look better with guidance 6-8 to keep the proportions.

### Suggested Generation Order
1. **Drone** — simplest, most common, instant visual impact
2. **Wall** — simple geometry, tests defensive unit rendering
3. **Tarsier** — small attack unit, tests weapon/claw detail
4. **Steelsplitter** — medium complexity, mechanical
5. **Centurion** — large unit, tests scale and imposing geometry

### What to Expect
- The AI generates a **rough concept mesh**, not a production model
- Expect 10,000-50,000 triangles (will need decimation later for game use)
- Textures are baked into the GLB — they're approximate, not hand-painted
- Some units will look great on first try, others need multiple seeds or manual cleanup in Blender

## Instance Management

### Check Status
```
!status
```
Shows: running/stopped, uptime, estimated cost, tunnel URL.

### Stop the Instance
```
!stop
```
Terminates the instance. Any unsaved work in ComfyUI is lost — always download your GLBs first.

### Auto-Shutdown
The instance automatically shuts down after **10 minutes of inactivity** (no browser connected and no GPU jobs running). A warning is posted to Discord 60 seconds before shutdown.

**A running generation job keeps the instance alive** — it won't shut down mid-generation even if you close your browser.

### Cost
- **Spot instance**: ~$0.40/hour (typical)
- **On-demand fallback**: ~$1.00/hour (if spot unavailable)
- A typical session (generate 5-10 models): ~$0.50-1.00

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Tunnel URL doesn't load | Wait 1-2 min after bot posts URL. If still down, `!stop` and `!start` again. |
| "Queue Prompt" does nothing | Check the queue panel — there may be an error on a node. Red nodes = errors. |
| Generation is very slow (>2 min) | First generation is always slower (model loading into GPU). Subsequent ones are faster. |
| Output looks wrong (flat/distorted) | Try a different seed, or increase steps to 30. Some sprites work better than others. |
| "CUDA out of memory" | You're running too high a resolution or the full (non-turbo) model. Switch to the turbo variant. |
| Browser disconnected | The instance keeps running. Just reopen the tunnel URL. Your queue continues. |
| Instance shut down unexpectedly | Check Discord for idle shutdown or spot interruption messages. `!start` to relaunch. |
