# Favorites Carousel — Design Spec

**Date:** 2026-03-28
**Scope:** Frontend changes to `infra/frontend/index.html` + small backend additions to `__init__.py`

## Overview

Add a favorites carousel to the Fabrication Terminal header for quick access to recently favorited 3D models, and reposition the star/reject buttons in the session history strip.

## Components

### 1. Header Favorites Badge

A star icon with a count badge in the header bar, to the right of the existing connection status / queue status area.

**Behavior:**
- Count fetched from `/fabricate/api/favorites` on page load
- **Loading state:** Badge shows `...` until the favorites fetch completes
- Count updates reactively when the user stars or unstars a model

**Hover — Recent Favorites Dropdown:**
- Floating dropdown appears below the badge
- 4-column grid showing the 12 most recent favorites (4x3), sorted by `favorited_at` desc
- If more than 12 favorites exist, the grid scrolls vertically with a scrollbar
- Each cell displays the unit's **sprite thumbnail** (loaded from the manifest, not a 3D render)
- Tooltip on each cell shows unit name + skin name
- Click a favorite:
  1. Selects the unit/skin in the left panel dropdowns
  2. Downloads the **specific favorited model** from S3 via `/fabricate/api/s3-model/{unit}/{skin}?format=glb&filename={filename}`
  3. Loads it into the 3D preview viewport
- Dropdown dismisses on mouse-leave or clicking outside
- **Empty state:** If no favorites exist, dropdown shows "No favorites yet — star a model to add it here"

**Click the badge itself:**
- Opens the existing full favorites overlay (no change to current overlay behavior)

### 2. Session History Strip — Button Repositioning

**Star button:** Positioned as a small star icon overlaid on the **top-right corner** of each session history card thumbnail. Semi-transparent when unstarred, solid amber when starred. This avoids competing with the unit name label for horizontal space in the narrow 90px cards.

**Thumbs-down button:** Same treatment — small icon overlaid on the **bottom-right corner** of each card thumbnail.

No other changes to session history behavior — still session-scoped, resets on page reload.

## Data Flow

```
Page load
  └─ GET /fabricate/api/favorites
       └─ Cache favorites array in memory
            └─ Render badge count (replace "..." placeholder)
            └─ Populate dropdown grid (sorted by favorited_at desc, limit 12 visible)

User stars a model (from session strip)
  └─ POST /fabricate/api/favorite  (existing endpoint)
  └─ Add to local favorites cache
  └─ Increment badge count
  └─ Prepend to dropdown grid

User unstars a model
  └─ POST /fabricate/api/unfavorite  (NEW endpoint)
       └─ Deletes .fav.json from S3
  └─ Remove from local favorites cache
  └─ Decrement badge count
  └─ Remove from dropdown grid

User clicks a favorite in dropdown
  └─ Set unit dropdown → favorite.unit
  └─ Set skin dropdown → favorite.skin
  └─ Trigger sprite preview update
  └─ GET /fabricate/api/s3-model/{unit}/{skin}?format=glb&filename={filename}
  └─ Load model into <model-viewer>
```

## Styling

- Badge uses the existing terminal dark theme (amber/gold star on dark background)
- Dropdown has a subtle border and shadow, matches the dark panel aesthetic
- Hover state on grid items: border highlight
- Selected/active favorite: amber border glow
- Star/thumbs-down overlays on history cards: 16px icons, semi-transparent background for readability

## Backend Changes

Two small additions to `__init__.py` (and `install-frontend.sh` for AMI baking):

### 1. `POST /fabricate/api/unfavorite`

Deletes a `.fav.json` file from S3.

**Request body:**
```json
{
  "unit": "amporilla",
  "skin": "Natural",
  "filename": "amporilla_Natural_3d_00001_.glb"
}
```

**Behavior:** Deletes `s3://prismata-3d-models/favorites/{unit}/{skin}/{filename}.fav.json`

### 2. `GET /fabricate/api/s3-model/{unit}/{skin}` — add `filename` query param

Currently serves `latest.{fmt}`. Add optional `filename` query parameter to serve a specific file:

- `?format=glb` → serves `models/{unit}/{skin}/latest.glb` (existing behavior)
- `?format=glb&filename=amporilla_Natural_3d_00001_.glb` → serves `models/{unit}/{skin}/amporilla_Natural_3d_00001_.glb`

This ensures favorites load the exact model that was favorited, not whatever `latest.glb` happens to be.

## Out of Scope

- 3D rendered thumbnails in the carousel — sprites only
- Full generation history table — separate feature
- Changes to the full favorites overlay behavior
