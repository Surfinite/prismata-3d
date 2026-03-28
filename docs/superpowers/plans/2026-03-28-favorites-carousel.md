# Favorites Carousel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a header favorites badge with hover carousel and reposition star/thumbs-down as overlays on session history cards.

**Architecture:** All frontend changes are in the single-file `infra/frontend/index.html` (CSS + HTML + JS). Two small backend endpoints are added to `infra/ami/install-frontend.sh` (which contains the `__init__.py` heredoc for the ComfyUI custom node). After all changes, deploy to running instance via `infra/frontend/deploy.sh` for the HTML, and SSM for the `__init__.py`.

**Tech Stack:** Vanilla HTML/CSS/JS (no frameworks), Python aiohttp (ComfyUI custom node), boto3 (S3 API)

---

### Task 1: Backend — Add unfavorite endpoint and filename param

**Files:**
- Modify: `infra/ami/install-frontend.sh:101-118` (s3_model function) and after line 159 (add unfavorite endpoint)

- [ ] **Step 1: Add `filename` query param support to `s3_model`**

In `infra/ami/install-frontend.sh`, find the `s3_model` function (the Python code inside the heredoc). Replace lines 101-118:

```python
@PromptServer.instance.routes.get("/fabricate/api/s3-model/{unit}/{skin}")
async def s3_model(request):
    """Download a model from S3. Uses 'filename' param if provided, otherwise latest."""
    unit = request.match_info["unit"]
    skin = request.match_info["skin"]
    fmt = request.query.get("format", "glb")
    filename = request.query.get("filename", "")
    try:
        s3 = _s3()
        if filename and ".." not in filename and "/" not in filename:
            key = f"models/{unit}/{skin}/{filename}"
        else:
            key = f"models/{unit}/{skin}/latest.{fmt}"
        obj = s3.get_object(Bucket=S3_BUCKET, Key=key)
        body = obj["Body"].read()
        content_type = "model/gltf-binary" if fmt == "glb" else "application/octet-stream"
        dl_name = filename if filename else f"latest.{fmt}"
        return web.Response(body=body, content_type=content_type,
                          headers={"Content-Disposition": f"inline; filename={dl_name}"})
    except Exception as e:
        status = 404 if "NoSuchKey" in str(type(e).__name__) else 500
        return web.Response(status=status, text=str(e))
```

- [ ] **Step 2: Add `POST /fabricate/api/unfavorite` endpoint**

In `infra/ami/install-frontend.sh`, add this new endpoint after the existing `s3_favorite` function (after line 159 in the heredoc):

```python
@PromptServer.instance.routes.post("/fabricate/api/unfavorite")
async def s3_unfavorite(request):
    """Remove a favorite from S3."""
    try:
        data = await request.json()
        unit = data.get("unit", "")
        skin = data.get("skin", "")
        filename = data.get("filename", "")
        if not unit or not skin or not filename:
            return web.Response(status=400, text="Missing fields")
        s3 = _s3()
        key = f"favorites/{unit}/{skin}/{filename}.fav.json"
        s3.delete_object(Bucket=S3_BUCKET, Key=key)
        return web.json_response({"ok": True})
    except Exception as e:
        return web.Response(status=500, text=str(e))
```

- [ ] **Step 3: Commit backend changes**

```bash
git add infra/ami/install-frontend.sh
git commit -m "feat: add unfavorite endpoint and filename param to s3-model"
```

---

### Task 2: Frontend CSS — Favorites badge, dropdown, and history card overlays

**Files:**
- Modify: `infra/frontend/index.html` (CSS section, around line 682)

- [ ] **Step 1: Add CSS for the header favorites badge and dropdown**

Insert the following CSS after the `.btn-thumbsdown:hover` rule block (after line 681 in index.html), before the `/* ── HISTORY STRIP ── */` comment:

```css
/* ── FAVORITES BADGE ── */
.favs-badge {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 4px 10px;
  border: 1px solid rgba(255, 215, 0, 0.3);
  border-radius: 12px;
  cursor: pointer;
  transition: all 0.2s;
  position: relative;
  font-family: var(--mono);
  font-size: 12px;
  color: #ffd700;
  background: none;
}
.favs-badge:hover {
  background: rgba(255, 215, 0, 0.1);
  border-color: #ffd700;
  box-shadow: 0 0 8px rgba(255, 215, 0, 0.3);
}
.favs-badge-star {
  font-size: 16px;
  line-height: 1;
}
.favs-badge-count {
  font-size: 11px;
  min-width: 12px;
  text-align: center;
}

/* ── FAVORITES DROPDOWN ── */
.favs-dropdown {
  display: none;
  position: absolute;
  top: 100%;
  right: 0;
  margin-top: 8px;
  background: var(--bg-panel);
  border: 1px solid rgba(255, 215, 0, 0.3);
  border-radius: 6px;
  padding: 10px;
  z-index: 200;
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.6);
  min-width: 280px;
}
.favs-dropdown-title {
  font-family: var(--mono);
  font-size: 10px;
  color: rgba(255, 215, 0, 0.7);
  text-transform: uppercase;
  letter-spacing: 1px;
  margin-bottom: 8px;
}
.favs-dropdown-grid {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 6px;
  max-height: 210px;
  overflow-y: auto;
}
.favs-dropdown-item {
  width: 60px;
  height: 60px;
  border: 1px solid var(--border);
  border-radius: 4px;
  background: var(--bg-input);
  cursor: pointer;
  overflow: hidden;
  transition: all 0.2s;
  position: relative;
}
.favs-dropdown-item:hover {
  border-color: #ffd700;
  box-shadow: 0 0 6px rgba(255, 215, 0, 0.3);
}
.favs-dropdown-item img {
  width: 100%;
  height: 100%;
  object-fit: contain;
}
.favs-dropdown-empty {
  color: var(--text-secondary);
  font-family: var(--mono);
  font-size: 11px;
  text-align: center;
  padding: 16px 8px;
}
.favs-badge-wrapper {
  position: relative;
}
```

- [ ] **Step 2: Add CSS for history card overlay star and thumbs-down buttons**

Find the existing `.history-card-star` rule (around line 758). Replace it with:

```css
.history-card-overlay {
  position: absolute;
  width: 20px;
  height: 20px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 14px;
  cursor: pointer;
  border-radius: 3px;
  background: rgba(0, 0, 0, 0.5);
  transition: all 0.2s;
  opacity: 0.4;
  border: none;
  padding: 0;
  line-height: 1;
}
.history-card:hover .history-card-overlay {
  opacity: 0.8;
}
.history-card-overlay:hover {
  opacity: 1 !important;
}
.history-card-overlay.star-btn {
  top: 2px;
  right: 2px;
  color: var(--text-secondary);
}
.history-card-overlay.star-btn.starred {
  color: #ffd700;
  opacity: 1;
  text-shadow: 0 0 4px rgba(255, 215, 0, 0.5);
}
.history-card-overlay.reject-btn {
  bottom: 2px;
  right: 2px;
  color: var(--text-secondary);
  font-size: 12px;
}
.history-card-overlay.reject-btn.rejected {
  color: var(--error);
  opacity: 1;
}
```

- [ ] **Step 3: Commit CSS changes**

```bash
git add infra/frontend/index.html
git commit -m "feat: add CSS for favorites badge, dropdown, and history card overlays"
```

---

### Task 3: Frontend HTML — Add header badge, remove old favorites button

**Files:**
- Modify: `infra/frontend/index.html` (HTML section, lines 1093-1104 header area, lines 1400-1435 preview panel)

- [ ] **Step 1: Add favorites badge to header**

Find the `.status-bar` div in the header (line 1100-1103). Replace it with:

```html
    <div class="status-bar">
      <span><span class="status-dot" id="connDot"></span><span id="connText">Checking...</span></span>
      <span id="queueStatus"></span>
      <div class="favs-badge-wrapper">
        <button class="favs-badge" id="favsBadge" title="View favorites">
          <span class="favs-badge-star">&#9733;</span>
          <span class="favs-badge-count" id="favsBadgeCount">...</span>
        </button>
        <div class="favs-dropdown" id="favsDropdown">
          <div class="favs-dropdown-title">Recent Favorites</div>
          <div class="favs-dropdown-grid" id="favsDropdownGrid"></div>
        </div>
      </div>
    </div>
```

- [ ] **Step 2: Remove old star button from preview header**

Find the `preview-title-group` div (lines 1404-1407). Replace it with:

```html
        <div class="preview-title-group">
          <span class="preview-title" id="previewTitle">3D Preview</span>
        </div>
```

This removes the `btnStar` button from the preview header — starring now happens on history cards.

- [ ] **Step 3: Remove old `btnThumbsDown` from preview header**

Find the `preview-actions` div (lines 1408-1417). Remove the thumbs-down button line:

```html
          <button class="btn-action btn-thumbsdown" id="btnThumbsDown" title="Mark as bad generation" disabled>&#128078;</button>
```

Thumbs-down is now an overlay on history cards instead.

- [ ] **Step 4: Remove old "Favorites" button from history strip header**

Find the `history-strip-header` div (lines 1431-1434). Replace it with:

```html
        <div class="history-strip-header">
          <span class="history-strip-title">Session History</span>
        </div>
```

This removes `btnViewFavorites` — the full overlay is now triggered by clicking the header badge.

- [ ] **Step 5: Commit HTML changes**

```bash
git add infra/frontend/index.html
git commit -m "feat: add favorites badge to header, remove old star/favs buttons"
```

---

### Task 4: Frontend JS — Favorites cache, badge, and dropdown

**Files:**
- Modify: `infra/frontend/index.html` (JS section, around lines 2485-2617)

- [ ] **Step 1: Add favorites cache and badge initialization**

Find the `// ── History & Favorites ──` comment (line 2485). Replace the block from there through `const historyStripInner = $('historyStripInner');` (line 2490) with:

```javascript
// ── History & Favorites ──
let sessionHistory = []; // { unit, skin, url, filename, params, starred, rejected, spriteUrl }
let currentHistoryIndex = -1;
let favoritesCache = []; // fetched from S3 on load
const historyStrip = $('historyStrip');
const historyStripInner = $('historyStripInner');
const favsBadge = $('favsBadge');
const favsBadgeCount = $('favsBadgeCount');
const favsDropdown = $('favsDropdown');
const favsDropdownGrid = $('favsDropdownGrid');
```

- [ ] **Step 2: Add favorites fetch and badge render functions**

Insert the following after the variable declarations above (before the `addToHistory` function):

```javascript
// Fetch favorites from S3 and populate badge + dropdown
async function loadFavorites() {
  try {
    const resp = await fetch(`${API_BASE}/fabricate/api/favorites`);
    if (!resp.ok) return;
    favoritesCache = await resp.json();
    favoritesCache.sort((a, b) => (b.favorited_at || '').localeCompare(a.favorited_at || ''));
  } catch (e) {
    favoritesCache = [];
  }
  renderFavsBadge();
  renderFavsDropdown();
}

function renderFavsBadge() {
  favsBadgeCount.textContent = favoritesCache.length;
}

function renderFavsDropdown() {
  favsDropdownGrid.innerHTML = '';
  if (favoritesCache.length === 0) {
    favsDropdownGrid.innerHTML = '<div class="favs-dropdown-empty">No favorites yet — star a model to add it here</div>';
    return;
  }
  for (const fav of favoritesCache) {
    const item = document.createElement('div');
    item.className = 'favs-dropdown-item';
    item.title = `${formatUnitName(fav.unit)} [${fav.skin}]`;

    // Use sprite from manifest
    const spritePath = manifest?.[fav.unit]?.[fav.skin];
    if (spritePath) {
      const img = document.createElement('img');
      const parts = spritePath.split('/');
      const filename = parts[parts.length - 1];
      const subfolder = parts.slice(0, -1).join('/');
      img.src = `${API_BASE}/api/view?filename=${encodeURIComponent(filename)}&type=input&subfolder=${encodeURIComponent(subfolder)}`;
      img.alt = fav.unit;
      item.appendChild(img);
    }

    item.addEventListener('click', () => loadFavoriteModel(fav));
    favsDropdownGrid.appendChild(item);
  }
}

async function loadFavoriteModel(fav) {
  // Close dropdown
  favsDropdown.style.display = 'none';

  // Select unit/skin in dropdowns
  unitSelect.value = fav.unit;
  unitSelect.dispatchEvent(new Event('change'));
  await new Promise(r => setTimeout(r, 100));
  skinSelect.value = fav.skin;
  skinSelect.dispatchEvent(new Event('change'));

  // Load the specific favorited model from S3
  const url = `${API_BASE}/fabricate/api/s3-model/${encodeURIComponent(fav.unit)}/${encodeURIComponent(fav.skin)}?format=glb${fav.filename ? '&filename=' + encodeURIComponent(fav.filename) : ''}`;
  previewTitle.textContent = `${formatUnitName(fav.unit)} — ${fav.skin}`;
  loadModelFromUrl(url, fav.filename || 'favorite.glb');
  log(`Loaded favorite: ${formatUnitName(fav.unit)} [${fav.skin}]`, 'success');
}
```

- [ ] **Step 3: Add hover/click handlers for badge and dropdown**

Insert the following right after the functions above:

```javascript
// Badge hover → show dropdown
let favsDropdownTimeout;
const favsBadgeWrapper = favsBadge.parentElement;

favsBadgeWrapper.addEventListener('mouseenter', () => {
  clearTimeout(favsDropdownTimeout);
  favsDropdown.style.display = 'block';
});
favsBadgeWrapper.addEventListener('mouseleave', () => {
  favsDropdownTimeout = setTimeout(() => {
    favsDropdown.style.display = 'none';
  }, 200);
});

// Badge click → open full favorites overlay
favsBadge.addEventListener('click', (e) => {
  e.stopPropagation();
  favsDropdown.style.display = 'none';
  showFavoritesOverlay();
});

// Close dropdown on outside click
document.addEventListener('click', (e) => {
  if (!favsBadgeWrapper.contains(e.target)) {
    favsDropdown.style.display = 'none';
  }
});
```

- [ ] **Step 4: Commit JS favorites cache and dropdown logic**

```bash
git add infra/frontend/index.html
git commit -m "feat: add favorites cache, badge rendering, and hover dropdown"
```

---

### Task 5: Frontend JS — Rework history cards with overlay star/thumbs-down

**Files:**
- Modify: `infra/frontend/index.html` (JS section — `addToHistory`, `renderHistory`, `loadFromHistory`, star/thumbs-down click handlers, favorites overlay)

- [ ] **Step 1: Update `addToHistory` to remove old btnStar references**

Replace the `addToHistory` function (lines 2492-2504) with:

```javascript
function addToHistory(unit, skin, modelUrl, filename, params) {
  const spriteUrl = spritePreview.src || '';
  const entry = { unit, skin, url: modelUrl, filename, params: params ? {...params} : null, starred: false, rejected: false, spriteUrl };
  sessionHistory.push(entry);
  currentHistoryIndex = sessionHistory.length - 1;
  renderHistory();
}
```

- [ ] **Step 2: Update `renderHistory` with overlay star and thumbs-down buttons**

Replace the `renderHistory` function (lines 2506-2528) with:

```javascript
function renderHistory() {
  if (sessionHistory.length === 0) {
    historyStrip.style.display = 'none';
    return;
  }
  historyStrip.style.display = '';
  historyStripInner.innerHTML = '';
  for (let i = 0; i < sessionHistory.length; i++) {
    const h = sessionHistory[i];
    const card = document.createElement('div');
    card.className = 'history-card' + (i === currentHistoryIndex ? ' active' : '');

    // Sprite image
    if (h.spriteUrl) {
      const img = document.createElement('img');
      img.className = 'history-card-img';
      img.src = h.spriteUrl;
      img.alt = h.unit;
      card.appendChild(img);
    } else {
      const placeholder = document.createElement('div');
      placeholder.className = 'history-card-img';
      card.appendChild(placeholder);
    }

    // Unit name label
    const label = document.createElement('div');
    label.className = 'history-card-label';
    label.textContent = formatUnitName(h.unit);
    card.appendChild(label);

    // Star overlay button (top-right)
    const starBtn = document.createElement('button');
    starBtn.className = 'history-card-overlay star-btn' + (h.starred ? ' starred' : '');
    starBtn.textContent = h.starred ? '\u2605' : '\u2606';
    starBtn.title = h.starred ? 'Remove from favorites' : 'Add to favorites';
    starBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      toggleStar(i);
    });
    card.appendChild(starBtn);

    // Thumbs-down overlay button (bottom-right)
    const rejectBtn = document.createElement('button');
    rejectBtn.className = 'history-card-overlay reject-btn' + (h.rejected ? ' rejected' : '');
    rejectBtn.textContent = '\u{1F44E}';
    rejectBtn.title = h.rejected ? 'Remove rejection' : 'Mark as bad generation';
    rejectBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      toggleReject(i);
    });
    card.appendChild(rejectBtn);

    card.addEventListener('click', () => loadFromHistory(i));
    historyStripInner.appendChild(card);
  }
  historyStripInner.scrollLeft = historyStripInner.scrollWidth;
}
```

- [ ] **Step 3: Simplify `loadFromHistory` (no more btnStar/btnThumbsDown updates)**

Replace the `loadFromHistory` function (lines 2530-2542) with:

```javascript
function loadFromHistory(index) {
  const h = sessionHistory[index];
  currentHistoryIndex = index;
  currentGenParams = h.params;
  loadModelFromUrl(h.url, h.filename);
  previewTitle.textContent = `${formatUnitName(h.unit)} — ${h.skin}`;
  renderHistory();
}
```

- [ ] **Step 4: Replace old star/thumbs-down click handlers with `toggleStar` and `toggleReject`**

Remove the old `btnStar.addEventListener('click', ...)` block (lines 2544-2559) and the old `btnThumbsDown.addEventListener('click', ...)` block (lines 2562-2578). Also remove the line `const btnStar = $('btnStar');` (line 2488) and `const btnThumbsDown = $('btnThumbsDown');` — these elements no longer exist in the HTML.

Replace them with:

```javascript
function toggleStar(index) {
  const h = sessionHistory[index];
  h.starred = !h.starred;
  renderHistory();

  if (h.starred && h.filename) {
    // Add to S3 + local cache
    fetch(`${API_BASE}/fabricate/api/favorite`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ unit: h.unit, skin: h.skin, filename: h.filename, params: h.params })
    }).catch(() => {});
    // Update local cache
    const fav = { unit: h.unit, skin: h.skin, filename: h.filename, params: h.params,
                  favorited_at: new Date().toISOString() };
    favoritesCache.unshift(fav);
    renderFavsBadge();
    renderFavsDropdown();
  } else if (!h.starred && h.filename) {
    // Remove from S3 + local cache
    fetch(`${API_BASE}/fabricate/api/unfavorite`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ unit: h.unit, skin: h.skin, filename: h.filename })
    }).catch(() => {});
    favoritesCache = favoritesCache.filter(f => !(f.unit === h.unit && f.skin === h.skin && f.filename === h.filename));
    renderFavsBadge();
    renderFavsDropdown();
  }
}

function toggleReject(index) {
  const h = sessionHistory[index];
  h.rejected = !h.rejected;
  renderHistory();

  if (h.rejected && h.filename) {
    fetch(`${API_BASE}/fabricate/api/reject`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ unit: h.unit, skin: h.skin, filename: h.filename, params: h.params })
    }).catch(() => {});
  }
}
```

- [ ] **Step 5: Extract `showFavoritesOverlay` from the old inline handler**

Remove the old `$('btnViewFavorites').addEventListener('click', ...)` block (lines 2580-2617). Replace it with a named function:

```javascript
async function showFavoritesOverlay() {
  try {
    // Use cache if available, otherwise fetch
    const favs = favoritesCache.length > 0 ? favoritesCache : await fetch(`${API_BASE}/fabricate/api/favorites`).then(r => r.json());
    if (favs.length === 0) {
      log('No favorites saved yet');
      return;
    }
    let overlay = $('favsOverlay');
    if (!overlay) {
      overlay = document.createElement('div');
      overlay.id = 'favsOverlay';
      overlay.style.cssText = 'position:fixed;inset:0;z-index:100;background:rgba(0,0,0,0.85);display:flex;flex-direction:column;align-items:center;padding:40px 20px;overflow-y:auto;';
      document.body.appendChild(overlay);
    }
    overlay.innerHTML = `
      <div style="max-width:800px;width:100%;">
        <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:20px;">
          <h2 style="font-family:var(--display);color:#ffd700;font-size:18px;letter-spacing:2px;">&#9733; FAVORITES</h2>
          <button onclick="this.closest('#favsOverlay').remove()" style="background:none;border:1px solid var(--border);color:var(--text-primary);padding:6px 14px;cursor:pointer;border-radius:3px;font-family:var(--mono);font-size:12px;">Close</button>
        </div>
        <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:12px;">
          ${favs.map(f => `
            <div style="border:1px solid var(--border);border-radius:4px;padding:10px;background:var(--bg-panel);cursor:pointer;" onclick="document.getElementById('favsOverlay').remove(); unitSelect.value='${f.unit}'; unitSelect.dispatchEvent(new Event('change')); setTimeout(()=>{skinSelect.value='${f.skin}'; skinSelect.dispatchEvent(new Event('change'));},100);">
              <div style="font-family:var(--display);font-size:13px;color:var(--text-primary);margin-bottom:4px;">${formatUnitName(f.unit)}</div>
              <div style="font-family:var(--mono);font-size:10px;color:var(--text-secondary);">[${f.skin}]</div>
              ${f.params ? `<div style="font-family:var(--mono);font-size:9px;color:var(--text-secondary);margin-top:6px;opacity:0.6;">steps:${f.params.steps || '?'} seed:${f.params.seed || '?'}${f.params.duration_seconds ? ' '+f.params.duration_seconds+'s' : ''}</div>` : ''}
              <div style="font-family:var(--mono);font-size:9px;color:rgba(255,215,0,0.5);margin-top:4px;">${f.favorited_at ? new Date(f.favorited_at).toLocaleDateString() : ''}</div>
            </div>
          `).join('')}
        </div>
      </div>
    `;
    overlay.style.display = 'flex';
  } catch (e) { log('Failed to load favorites: ' + e.message, 'error'); }
}
```

- [ ] **Step 6: Add `loadFavorites()` call to the `init()` function**

Find the `init()` function and add `loadFavorites();` after the manifest is loaded (after `populateUnits()` is called). The favorites fetch needs the manifest to be available for sprite URLs. Look for the section where `populateUnits()` is called and add right after it:

```javascript
loadFavorites();
```

- [ ] **Step 7: Remove the old `btnThumbsDown` JS declaration**

Find and remove this line (around line 2562):
```javascript
const btnThumbsDown = $('btnThumbsDown');
```

(The HTML element was already removed in Task 3 step 3.)

- [ ] **Step 8: Commit JS changes**

```bash
git add infra/frontend/index.html
git commit -m "feat: rework history cards with overlay star/thumbs-down, wire favorites cache"
```

---

### Task 6: Test and deploy

- [ ] **Step 1: Verify the HTML is valid**

Open `infra/frontend/index.html` in a browser locally (or use a simple HTTP server) to check for JS console errors. Verify:
- No reference errors for removed elements (`btnStar`, `btnThumbsDown`, `btnViewFavorites`)
- Favorites badge renders with "..." on load
- No CSS visual regressions in the header

- [ ] **Step 2: Deploy HTML to S3**

```bash
aws s3 cp infra/frontend/index.html s3://prismata-3d-models/frontend/index.html --region us-east-1
```

- [ ] **Step 3: Deploy backend changes to running instance (if one exists)**

Upload the updated `__init__.py` and restart ComfyUI. The deploy script handles the HTML, but for `__init__.py` changes, use SSM:

```bash
# Check for running instance
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=prismata-3d-gen" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text --region us-east-1)

# If an instance is running, deploy both HTML and __init__.py
if [ "$INSTANCE_ID" != "None" ]; then
  bash infra/frontend/deploy.sh "$INSTANCE_ID"
fi
```

For the `__init__.py`, it will be baked in at next AMI build. For a running instance, you can manually deploy via SSM by uploading the updated `install-frontend.sh` to S3 and running it, or by directly updating the file on the instance.

- [ ] **Step 4: Test on live instance**

If a ComfyUI instance is running:
1. Open the Fabrication Terminal URL
2. Verify the favorites badge appears in the header with a count
3. Hover the badge — verify the dropdown shows sprite thumbnails
4. Click a favorite in the dropdown — verify it loads the model and selects the unit/skin
5. Generate a new model, star it from the history card overlay — verify badge count increments and it appears in the dropdown
6. Unstar it — verify badge count decrements and it disappears from the dropdown
7. Click the badge — verify the full favorites overlay opens
8. Verify thumbs-down overlay works on history cards

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "feat: favorites carousel — header badge with hover dropdown"
```
