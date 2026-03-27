# Phase 0: Asset Preparation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract all Prismata unit sprites (all skins) and build a portable manifest with text descriptions, so the AWS pipeline has clean, self-contained input data with no Windows path dependencies.

**Architecture:** Three Python scripts in `tools/prismata_asset_prep/` that read from local Prismata game files and produce a portable output directory. Each script is independent and testable. A fourth script orchestrates all three.

**Tech Stack:** Python 3.13, Pillow (PIL), standard library (struct, json, os). No other dependencies.

**Spec:** `docs/superpowers/specs/2026-03-27-batch-3d-model-generation-pipeline.md` — Phase 0 section.

---

## File Structure

```
tools/prismata_asset_prep/
  extract_skins.py          — Extract PNGs from .skin archive files
  extract_animated_frames.py — Extract best frame from animated .batch files
  build_manifest.py         — Build manifest.json + descriptions.json from cardLibrary + sprites
  run_all.py                — Orchestrator: runs all three, validates output
  batch_format.py           — Shared: parse the .skin/.batch archive format
  test_batch_format.py      — Tests for archive parser
  test_extract_skins.py     — Tests for skin extraction
  test_extract_animated.py  — Tests for animated frame extraction
  test_build_manifest.py    — Tests for manifest builder

generated/prismata_3d_input/
  units/{unit}/{skin}.png   — Extracted sprites (300x300 RGBA)
  manifest.json             — unit → skins → file paths
  descriptions.json         — unit → text description for 3D generation
```

### Source data locations (read-only):
- `C:/libraries/Prismata/newUnitArt/*.skin` — 627 skin archive files
- `C:/libraries/Prismata/animatedUnit/*_large.batch` — 16 animated skin sprite sheets
- `C:/libraries/PrismataAI/bin/asset/config/cardLibrary.jso` — card mechanics data
- `assets/card_sprites/*.png` — 143 base card sprites (103 at 300x300, 40 at 128x128)

---

### Task 1: Batch Archive Format Parser

**Files:**
- Create: `tools/prismata_asset_prep/batch_format.py`
- Create: `tools/prismata_asset_prep/test_batch_format.py`

This is the shared parser for both `.skin` and `.batch` files. Both use the same archive format:
```
[4 bytes] num_files (uint32 LE)
[repeat num_files]:
  [64 bytes] filename (ASCII, space-padded)
  [4 bytes]  file_size (uint32 LE)
[concatenated file data in order]
```

- [ ] **Step 1: Write failing test for header parsing**

```python
# tools/prismata_asset_prep/test_batch_format.py
import struct
import pytest
from batch_format import parse_batch_archive


def _make_archive(files: dict[str, bytes]) -> bytes:
    """Build a minimal .skin/.batch archive from {name: data} pairs."""
    num = len(files)
    header = struct.pack("<I", num)
    toc = b""
    body = b""
    for name, data in files.items():
        name_bytes = name.encode("ascii")
        padded = name_bytes.ljust(64, b" ")
        toc += padded + struct.pack("<I", len(data))
        body += data
    return header + toc + body


def test_parse_single_file():
    payload = b"hello world"
    archive = _make_archive({"test.txt": payload})
    result = parse_batch_archive(archive)
    assert len(result) == 1
    assert result[0].name == "test.txt"
    assert result[0].data == payload


def test_parse_multiple_files():
    archive = _make_archive({"a.png": b"\x89PNG_fake_a", "b.xml": b"<xml/>"})
    result = parse_batch_archive(archive)
    assert len(result) == 2
    assert result[0].name == "a.png"
    assert result[0].data == b"\x89PNG_fake_a"
    assert result[1].name == "b.xml"
    assert result[1].data == b"<xml/>"


def test_parse_empty_archive():
    archive = struct.pack("<I", 0)
    result = parse_batch_archive(archive)
    assert result == []


def test_names_are_stripped():
    archive = _make_archive({"padded.png": b"data"})
    result = parse_batch_archive(archive)
    assert result[0].name == "padded.png"  # no trailing spaces
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd tools/prismata_asset_prep && python -m pytest test_batch_format.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'batch_format'`

- [ ] **Step 3: Implement the parser**

```python
# tools/prismata_asset_prep/batch_format.py
"""
Parser for Prismata .skin and .batch archive format.

Format:
  [4 bytes] num_files (uint32 LE)
  [repeat num_files]:
    [64 bytes] filename (ASCII, space-padded)
    [4 bytes]  file_size (uint32 LE)
  [concatenated file data in entry order]
"""
import struct
from dataclasses import dataclass


@dataclass
class ArchiveEntry:
    name: str
    data: bytes


def parse_batch_archive(data: bytes) -> list[ArchiveEntry]:
    """Parse a .skin or .batch archive, return list of (name, data) entries."""
    if len(data) < 4:
        return []
    num_files = struct.unpack_from("<I", data, 0)[0]
    if num_files == 0:
        return []

    offset = 4
    toc: list[tuple[str, int]] = []
    for _ in range(num_files):
        raw_name = data[offset : offset + 64]
        name = raw_name.split(b"\x00")[0].rstrip(b" ").decode("ascii", errors="replace")
        offset += 64
        size = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        toc.append((name, size))

    entries: list[ArchiveEntry] = []
    for name, size in toc:
        entries.append(ArchiveEntry(name=name, data=data[offset : offset + size]))
        offset += size

    return entries
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tools/prismata_asset_prep && python -m pytest test_batch_format.py -v`
Expected: All 4 tests PASS

- [ ] **Step 5: Integration test with a real .skin file**

Add to `test_batch_format.py`:
```python
import os

SKIN_PATH = "C:/libraries/Prismata/newUnitArt/Drone_Regular_all.skin"


@pytest.mark.skipif(not os.path.exists(SKIN_PATH), reason="Prismata not installed")
def test_parse_real_skin_file():
    with open(SKIN_PATH, "rb") as f:
        data = f.read()
    entries = parse_batch_archive(data)
    assert len(entries) == 6  # buySD, buyHD, infoSD, infoHD, instSD, instHD
    names = [e.name for e in entries]
    assert any("infoHD" in n for n in names)
    # Each entry should start with PNG magic
    for e in entries:
        if e.name.endswith(".png"):
            assert e.data[:4] == b"\x89PNG", f"{e.name} is not a valid PNG"
```

- [ ] **Step 6: Run all tests**

Run: `cd tools/prismata_asset_prep && python -m pytest test_batch_format.py -v`
Expected: All 5 tests PASS

- [ ] **Step 7: Commit**

```bash
git add tools/prismata_asset_prep/batch_format.py tools/prismata_asset_prep/test_batch_format.py
git commit -m "feat: add Prismata .skin/.batch archive parser with tests"
```

---

### Task 2: Skin Extractor

**Files:**
- Create: `tools/prismata_asset_prep/extract_skins.py`
- Create: `tools/prismata_asset_prep/test_extract_skins.py`

Extracts the best available sprite (infoHD preferred, 300x300) from each `.skin` file. Also copies base card sprites for units without `.skin` files.

- [ ] **Step 1: Write failing tests**

```python
# tools/prismata_asset_prep/test_extract_skins.py
import os
import struct
import tempfile
import pytest
from PIL import Image
from extract_skins import extract_best_sprite, extract_all_skins


def _make_png(width: int, height: int) -> bytes:
    """Create a minimal valid PNG in memory."""
    import io
    img = Image.new("RGBA", (width, height), (255, 0, 0, 255))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _make_skin_archive(pngs: dict[str, tuple[int, int]]) -> bytes:
    """Build a fake .skin archive with named PNGs of given dimensions."""
    num = len(pngs)
    header = struct.pack("<I", num)
    toc = b""
    body = b""
    for name, (w, h) in pngs.items():
        png_data = _make_png(w, h)
        padded = name.encode("ascii").ljust(64, b" ")
        toc += padded + struct.pack("<I", len(png_data))
        body += png_data
    return header + toc + body


def test_extract_best_sprite_prefers_infohd():
    archive_data = _make_skin_archive({
        "Unit_Regular_buySD.png": (76, 35),
        "Unit_Regular_buyHD.png": (137, 63),
        "Unit_Regular_infoSD.png": (167, 167),
        "Unit_Regular_infoHD.png": (300, 300),
        "Unit_Regular_instSD.png": (74, 74),
        "Unit_Regular_instHD.png": (133, 133),
    })
    img = extract_best_sprite(archive_data)
    assert img.size == (300, 300)


def test_extract_best_sprite_falls_back_to_largest():
    archive_data = _make_skin_archive({
        "Unit_Regular_instHD.png": (133, 133),
        "Unit_Regular_instSD.png": (74, 74),
    })
    img = extract_best_sprite(archive_data)
    assert img.size == (133, 133)


def test_extract_all_skins_creates_output_files():
    with tempfile.TemporaryDirectory() as skin_dir, \
         tempfile.TemporaryDirectory() as sprite_dir, \
         tempfile.TemporaryDirectory() as out_dir:
        # Create a fake .skin file
        archive = _make_skin_archive({
            "Drone_Regular_infoHD.png": (300, 300),
        })
        with open(os.path.join(skin_dir, "Drone_Regular_all.skin"), "wb") as f:
            f.write(archive)

        # Create a base sprite for a unit with no skin
        base_img = Image.new("RGBA", (128, 128), (0, 255, 0, 255))
        base_img.save(os.path.join(sprite_dir, "barrier_forge.png"))

        result = extract_all_skins(
            skin_dir=skin_dir,
            base_sprite_dir=sprite_dir,
            output_dir=out_dir,
        )
        # Drone/Regular.png should exist
        assert os.path.exists(os.path.join(out_dir, "units", "drone", "Regular.png"))
        # barrier_forge with no skin should fall back to base sprite
        assert os.path.exists(os.path.join(out_dir, "units", "barrier_forge", "Regular.png"))
        assert "drone" in result
        assert "barrier_forge" in result
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd tools/prismata_asset_prep && python -m pytest test_extract_skins.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'extract_skins'`

- [ ] **Step 3: Implement the skin extractor**

```python
# tools/prismata_asset_prep/extract_skins.py
"""
Extract best-quality sprite from each Prismata .skin archive file.

Preference order: infoHD (300x300) > largest PNG > any PNG.
Also copies base card sprites for units without .skin files.

Usage:
  python extract_skins.py [--skin-dir DIR] [--sprite-dir DIR] [--output-dir DIR]
"""
import os
import io
import re
import argparse
from PIL import Image
from batch_format import parse_batch_archive


def extract_best_sprite(archive_data: bytes) -> Image.Image | None:
    """Extract the best (largest) PNG from a .skin archive, preferring infoHD."""
    entries = parse_batch_archive(archive_data)
    png_entries = []
    for e in entries:
        if not e.name.endswith(".png"):
            continue
        try:
            img = Image.open(io.BytesIO(e.data))
            png_entries.append((e.name, img))
        except Exception:
            continue

    if not png_entries:
        return None

    # Prefer infoHD
    for name, img in png_entries:
        if "infoHD" in name:
            return img.convert("RGBA")

    # Fall back to largest by pixel count
    png_entries.sort(key=lambda x: x[1].size[0] * x[1].size[1], reverse=True)
    return png_entries[0][1].convert("RGBA")


def _parse_skin_filename(filename: str) -> tuple[str, str] | None:
    """Parse 'Unit Name_SkinName_all.skin' -> (unit_name, skin_name).

    Returns snake_case unit name and original skin name.
    """
    basename = filename.replace("_all.skin", "")
    # Split on last underscore to get unit_name and skin_name
    # But unit names can contain underscores... the skin name is the part after
    # the LAST underscore that isn't part of the unit name.
    # Skin files are: "Unit Name_SkinName_all.skin"
    # The unit name uses spaces, skin name is one word (or CamelCase).
    parts = basename.rsplit("_", 1)
    if len(parts) != 2:
        return None
    unit_raw, skin_name = parts
    # Normalize unit name: spaces to underscores, lowercase
    unit_name = unit_raw.replace(" ", "_").lower()
    return unit_name, skin_name


def extract_all_skins(
    skin_dir: str,
    base_sprite_dir: str,
    output_dir: str,
) -> dict[str, list[str]]:
    """Extract all skins, return {unit_name: [skin_names]} mapping.

    For each .skin file, extracts the best PNG.
    For units with no .skin file, copies the base card sprite as Regular.
    """
    units: dict[str, list[str]] = {}
    units_dir = os.path.join(output_dir, "units")

    # Process .skin files
    skin_files = [f for f in os.listdir(skin_dir) if f.endswith("_all.skin")]
    for skin_file in sorted(skin_files):
        parsed = _parse_skin_filename(skin_file)
        if parsed is None:
            continue
        unit_name, skin_name = parsed

        with open(os.path.join(skin_dir, skin_file), "rb") as f:
            archive_data = f.read()

        img = extract_best_sprite(archive_data)
        if img is None:
            continue

        out_path = os.path.join(units_dir, unit_name)
        os.makedirs(out_path, exist_ok=True)
        img.save(os.path.join(out_path, f"{skin_name}.png"))

        units.setdefault(unit_name, []).append(skin_name)

    # Fill in units that have no .skin files — use base sprite as Regular
    if base_sprite_dir and os.path.isdir(base_sprite_dir):
        for sprite_file in sorted(os.listdir(base_sprite_dir)):
            if not sprite_file.endswith(".png"):
                continue
            unit_name = sprite_file.replace(".png", "")
            if unit_name in units and "Regular" in units[unit_name]:
                continue  # Already have a Regular skin from .skin file

            img = Image.open(os.path.join(base_sprite_dir, sprite_file)).convert("RGBA")
            out_path = os.path.join(units_dir, unit_name)
            os.makedirs(out_path, exist_ok=True)
            img.save(os.path.join(out_path, "Regular.png"))

            units.setdefault(unit_name, []).append("Regular")

    return units


def main():
    parser = argparse.ArgumentParser(description="Extract Prismata skin sprites")
    parser.add_argument("--skin-dir", default="C:/libraries/Prismata/newUnitArt")
    parser.add_argument("--sprite-dir", default="assets/card_sprites")
    parser.add_argument("--output-dir", default="generated/prismata_3d_input")
    args = parser.parse_args()

    print(f"Extracting skins from {args.skin_dir}")
    units = extract_all_skins(args.skin_dir, args.sprite_dir, args.output_dir)
    total_skins = sum(len(v) for v in units.values())
    print(f"Extracted {total_skins} sprites for {len(units)} units")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tools/prismata_asset_prep && python -m pytest test_extract_skins.py -v`
Expected: All 3 tests PASS

- [ ] **Step 5: Run on real data and verify output**

Run: `cd tools/prismata_asset_prep && python extract_skins.py`
Expected output: `Extracted ~670+ sprites for ~143 units`
Verify: `ls generated/prismata_3d_input/units/drone/` should show Regular.png plus country flag skins.

- [ ] **Step 6: Commit**

```bash
git add tools/prismata_asset_prep/extract_skins.py tools/prismata_asset_prep/test_extract_skins.py
git commit -m "feat: add skin sprite extractor for all Prismata units"
```

---

### Task 3: Animated Frame Extractor

**Files:**
- Create: `tools/prismata_asset_prep/extract_animated_frames.py`
- Create: `tools/prismata_asset_prep/test_extract_animated.py`

Extracts the first frame (frame "00") from animated `.batch` sprite sheets. These override any existing skin sprite for the same unit/skin combo since they may be higher quality.

- [ ] **Step 1: Write failing tests**

```python
# tools/prismata_asset_prep/test_extract_animated.py
import os
import io
import struct
import tempfile
import xml.etree.ElementTree as ET
import pytest
from PIL import Image
from extract_animated_frames import extract_first_frame, extract_all_animated


def _make_sprite_sheet(cols: int, rows: int, frame_size: int = 300) -> bytes:
    """Create a sprite sheet PNG with colored frames."""
    width = cols * (frame_size + 2) + 1  # +2 for 1px padding between frames, +1 for left
    height = rows * (frame_size + 2) + 1
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    # Fill each frame with a distinct color
    for r in range(rows):
        for c in range(cols):
            x = 1 + c * (frame_size + 2)
            y = 1 + r * (frame_size + 2)
            color = ((c * 50 + r * 80) % 256, (c * 30 + 100) % 256, (r * 60 + 50) % 256, 255)
            for py in range(frame_size):
                for px in range(frame_size):
                    img.putpixel((x + px, y + py), color)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def _make_atlas_xml(cols: int, rows: int, frame_size: int = 300) -> bytes:
    """Create TexturePacker-style XML atlas metadata."""
    lines = ['<TextureAtlas imagePath="animHD.png">']
    idx = 0
    for r in range(rows):
        for c in range(cols):
            x = 1 + c * (frame_size + 2)
            y = 1 + r * (frame_size + 2)
            lines.append(
                f'    <SubTexture name="{idx:02d}" x="{x}" y="{y}" '
                f'width="{frame_size}" height="{frame_size}"/>'
            )
            idx += 1
    lines.append("</TextureAtlas>")
    return "\n".join(lines).encode("utf-8")


def _make_batch_archive(png_data: bytes, xml_data: bytes) -> bytes:
    """Build a .batch archive with a PNG and XML."""
    num = 2
    header = struct.pack("<I", num)
    toc = b""
    toc += b"animHD.png".ljust(64, b" ") + struct.pack("<I", len(png_data))
    toc += b"_animHD.xml".ljust(64, b" ") + struct.pack("<I", len(xml_data))
    return header + toc + png_data + xml_data


def test_extract_first_frame():
    png_data = _make_sprite_sheet(6, 3)
    xml_data = _make_atlas_xml(6, 3)
    archive = _make_batch_archive(png_data, xml_data)
    frame = extract_first_frame(archive)
    assert frame is not None
    assert frame.size == (300, 300)


def test_extract_all_animated():
    with tempfile.TemporaryDirectory() as anim_dir, \
         tempfile.TemporaryDirectory() as out_dir:
        os.makedirs(os.path.join(out_dir, "units"), exist_ok=True)
        png_data = _make_sprite_sheet(3, 2)
        xml_data = _make_atlas_xml(3, 2)
        archive = _make_batch_archive(png_data, xml_data)
        with open(os.path.join(anim_dir, "Erebos_Regular_large.batch"), "wb") as f:
            f.write(archive)

        result = extract_all_animated(anim_dir, out_dir)
        assert "erebos" in result
        assert os.path.exists(os.path.join(out_dir, "units", "erebos", "Regular.png"))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd tools/prismata_asset_prep && python -m pytest test_extract_animated.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'extract_animated_frames'`

- [ ] **Step 3: Implement the animated frame extractor**

```python
# tools/prismata_asset_prep/extract_animated_frames.py
"""
Extract first animation frame from Prismata animated skin .batch files.

Each _large.batch contains a sprite sheet PNG + XML atlas metadata.
We extract frame "00" (the first frame) as the representative sprite.

Usage:
  python extract_animated_frames.py [--anim-dir DIR] [--output-dir DIR]
"""
import os
import io
import argparse
import xml.etree.ElementTree as ET
from PIL import Image
from batch_format import parse_batch_archive


def extract_first_frame(archive_data: bytes) -> Image.Image | None:
    """Extract the first animation frame from a .batch sprite sheet."""
    entries = parse_batch_archive(archive_data)

    png_entry = None
    xml_entry = None
    for e in entries:
        if e.name.endswith(".png"):
            png_entry = e
        elif e.name.endswith(".xml"):
            xml_entry = e

    if png_entry is None:
        return None

    sheet = Image.open(io.BytesIO(png_entry.data)).convert("RGBA")

    if xml_entry is None:
        # No atlas metadata — just return top-left 300x300
        return sheet.crop((0, 0, min(300, sheet.width), min(300, sheet.height)))

    # Parse XML atlas to find frame "00"
    xml_text = xml_entry.data.decode("utf-8", errors="replace")
    root = ET.fromstring(xml_text)
    for sub in root.findall("SubTexture"):
        if sub.get("name") == "00":
            x = int(sub.get("x", 0))
            y = int(sub.get("y", 0))
            w = int(sub.get("width", 300))
            h = int(sub.get("height", 300))
            return sheet.crop((x, y, x + w, y + h))

    # No frame "00" found — take the first SubTexture
    first = root.find("SubTexture")
    if first is not None:
        x = int(first.get("x", 0))
        y = int(first.get("y", 0))
        w = int(first.get("width", 300))
        h = int(first.get("height", 300))
        return sheet.crop((x, y, x + w, y + h))

    return None


def _parse_batch_filename(filename: str) -> tuple[str, str] | None:
    """Parse 'Unit Name_SkinName_large.batch' -> (unit_name, skin_name)."""
    basename = filename.replace("_large.batch", "")
    parts = basename.rsplit("_", 1)
    if len(parts) != 2:
        return None
    unit_raw, skin_name = parts
    unit_name = unit_raw.replace(" ", "_").lower()
    return unit_name, skin_name


def extract_all_animated(
    anim_dir: str,
    output_dir: str,
) -> dict[str, list[str]]:
    """Extract first frame from all animated skins, return {unit: [skins]} added."""
    units: dict[str, list[str]] = {}
    batch_files = [f for f in os.listdir(anim_dir) if f.endswith("_large.batch")]

    for batch_file in sorted(batch_files):
        parsed = _parse_batch_filename(batch_file)
        if parsed is None:
            continue
        unit_name, skin_name = parsed

        with open(os.path.join(anim_dir, batch_file), "rb") as f:
            archive_data = f.read()

        frame = extract_first_frame(archive_data)
        if frame is None:
            continue

        out_path = os.path.join(output_dir, "units", unit_name)
        os.makedirs(out_path, exist_ok=True)
        frame.save(os.path.join(out_path, f"{skin_name}.png"))

        units.setdefault(unit_name, []).append(skin_name)

    return units


def main():
    parser = argparse.ArgumentParser(description="Extract animated skin frames")
    parser.add_argument("--anim-dir", default="C:/libraries/Prismata/animatedUnit")
    parser.add_argument("--output-dir", default="generated/prismata_3d_input")
    args = parser.parse_args()

    print(f"Extracting animated frames from {args.anim_dir}")
    units = extract_all_animated(args.anim_dir, args.output_dir)
    total = sum(len(v) for v in units.values())
    print(f"Extracted {total} animated frames for {len(units)} units")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tools/prismata_asset_prep && python -m pytest test_extract_animated.py -v`
Expected: All 2 tests PASS

- [ ] **Step 5: Commit**

```bash
git add tools/prismata_asset_prep/extract_animated_frames.py tools/prismata_asset_prep/test_extract_animated.py
git commit -m "feat: add animated skin frame extractor"
```

---

### Task 4: Manifest Builder

**Files:**
- Create: `tools/prismata_asset_prep/build_manifest.py`
- Create: `tools/prismata_asset_prep/test_build_manifest.py`

Builds `manifest.json` (unit→skins→paths) and `descriptions.json` (unit→text for 3D generation). Since neither cardLibrary.jso nor the wiki reference contain visual descriptions, we generate descriptions from the card's mechanical role + name.

- [ ] **Step 1: Write failing tests**

```python
# tools/prismata_asset_prep/test_build_manifest.py
import os
import json
import tempfile
import pytest
from build_manifest import build_manifest, build_descriptions, generate_visual_description


def test_generate_visual_description_basic():
    desc = generate_visual_description("Drone", {"buyCost": "3H", "toughness": 1})
    assert "Drone" in desc
    assert isinstance(desc, str)
    assert len(desc) > 20


def test_generate_visual_description_unknown_unit():
    desc = generate_visual_description("MadeUpUnit", {})
    assert "MadeUpUnit" in desc


def test_build_manifest_from_directory():
    with tempfile.TemporaryDirectory() as out_dir:
        units_dir = os.path.join(out_dir, "units")
        # Create fake extracted sprites
        for unit, skins in [("drone", ["Regular", "USA"]), ("aegis", ["Regular"])]:
            unit_dir = os.path.join(units_dir, unit)
            os.makedirs(unit_dir)
            for skin in skins:
                with open(os.path.join(unit_dir, f"{skin}.png"), "wb") as f:
                    f.write(b"fake png")

        manifest = build_manifest(out_dir)
        assert "drone" in manifest
        assert "Regular" in manifest["drone"]
        assert manifest["drone"]["Regular"] == "units/drone/Regular.png"
        assert "aegis" in manifest
        assert len(manifest["drone"]) == 2


def test_build_descriptions():
    card_library = {
        "Drone": {"buyCost": "3H", "toughness": 1, "baseSet": 1},
        "Aegis": {"buyCost": "4", "toughness": 5, "rarity": "legendary"},
    }
    unit_names = ["drone", "aegis"]
    descriptions = build_descriptions(unit_names, card_library)
    assert "drone" in descriptions
    assert "aegis" in descriptions
    assert isinstance(descriptions["drone"], str)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd tools/prismata_asset_prep && python -m pytest test_build_manifest.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'build_manifest'`

- [ ] **Step 3: Implement the manifest builder**

```python
# tools/prismata_asset_prep/build_manifest.py
"""
Build manifest.json and descriptions.json for the 3D model generation pipeline.

manifest.json: {unit_name: {skin_name: relative_path_to_png}}
descriptions.json: {unit_name: "text description for 3D generation"}

Since Prismata has no visual/lore descriptions in its data files, we generate
descriptions from the unit name + mechanical role to give the 3D model generator
context about what each unit should look like.

Usage:
  python build_manifest.py [--output-dir DIR] [--card-library PATH]
"""
import os
import json
import argparse


# Role descriptions based on game mechanics — helps the 3D generator understand
# what kind of thing each unit is (attacker, defender, building, etc.)
ROLE_HINTS = {
    "trinket": "small common unit",
    "normal": "standard combat unit",
    "legendary": "powerful rare unit",
}

KNOWN_VISUALS = {
    "drone": "A small floating robotic worker drone with a single glowing eye and metallic shell",
    "engineer": "A robotic cyborg head with dark metallic armor plating, angular jaw, and glowing orange eyes",
    "wall": "A large defensive barrier structure, thick and imposing",
    "blastforge": "An industrial forge building with glowing furnace and heavy metal construction",
    "animus": "A dark, menacing structure crackling with red energy",
    "conduit": "A sleek green energy conduit with flowing power channels",
    "tarsier": "A small aggressive creature with large eyes and sharp claws",
    "rhino": "A heavy armored beast, rhinoceros-like with mechanical augmentation",
    "steelsplitter": "A fast mechanical construct with bladed appendages",
    "gauss_cannon": "A heavy energy cannon mounted on a sturdy base platform",
    "forcefield": "A shimmering translucent energy shield barrier",
    "aegis": "A large ornate defensive structure with layered armor plating",
    "apollo": "A sleek attack unit with aerodynamic design and weapon systems",
    "odin": "A massive heavily-armored war machine, imposing and powerful",
    "cynestra": "A dark ethereal figure with flowing energy and sinister presence",
    "erebos": "A shadowy demonic entity radiating dark energy",
    "bloodrager": "A fierce berserker creature with red-tinged armor and aggressive stance",
    "frostbite": "An icy creature with frozen crystalline features and cold aura",
    "shiver_yeti": "A large furry yeti creature with ice powers and massive build",
    "xeno_guardian": "An alien guardian unit with bio-mechanical features and protective stance",
    "defense_grid": "A grid-like defensive array structure with multiple shield projectors",
    "grenade_mech": "A stocky mechanical unit armed with explosive grenade launchers",
}


def generate_visual_description(unit_display_name: str, card_data: dict) -> str:
    """Generate a text description for 3D model generation.

    Uses known visual descriptions where available, otherwise constructs
    a generic description from the unit name and mechanical properties.
    """
    unit_key = unit_display_name.replace(" ", "_").lower()

    if unit_key in KNOWN_VISUALS:
        base = KNOWN_VISUALS[unit_key]
    else:
        base = f"{unit_display_name}, a sci-fi strategy game unit"

    rarity = card_data.get("rarity", "normal")
    role = ROLE_HINTS.get(rarity, "combat unit")

    return f"{base}. Prismata {role}, stylized game asset, low-poly 3D model"


def build_manifest(output_dir: str) -> dict[str, dict[str, str]]:
    """Scan output_dir/units/ and build {unit: {skin: relative_path}} manifest."""
    manifest: dict[str, dict[str, str]] = {}
    units_dir = os.path.join(output_dir, "units")

    if not os.path.isdir(units_dir):
        return manifest

    for unit_name in sorted(os.listdir(units_dir)):
        unit_path = os.path.join(units_dir, unit_name)
        if not os.path.isdir(unit_path):
            continue
        skins: dict[str, str] = {}
        for skin_file in sorted(os.listdir(unit_path)):
            if not skin_file.endswith(".png"):
                continue
            skin_name = skin_file.replace(".png", "")
            skins[skin_name] = f"units/{unit_name}/{skin_file}"
        if skins:
            manifest[unit_name] = skins

    return manifest


def build_descriptions(
    unit_names: list[str],
    card_library: dict,
) -> dict[str, str]:
    """Build {unit_name: description} mapping for all units."""
    descriptions: dict[str, str] = {}

    # Build a lookup from snake_case to card library key
    card_lookup: dict[str, tuple[str, dict]] = {}
    for card_name, card_data in card_library.items():
        # Card library uses display names like "Drone", "Tesla Tower"
        # UIName overrides the key name
        display = card_data.get("UIName", card_name)
        key = card_name.replace(" ", "_").lower()
        card_lookup[key] = (display, card_data)
        # Also map by UIName
        ui_key = display.replace(" ", "_").lower()
        if ui_key != key:
            card_lookup[ui_key] = (display, card_data)

    for unit_name in unit_names:
        if unit_name in card_lookup:
            display, data = card_lookup[unit_name]
        else:
            display = unit_name.replace("_", " ").title()
            data = {}
        descriptions[unit_name] = generate_visual_description(display, data)

    return descriptions


def main():
    parser = argparse.ArgumentParser(description="Build manifest and descriptions")
    parser.add_argument("--output-dir", default="generated/prismata_3d_input")
    parser.add_argument(
        "--card-library",
        default="C:/libraries/PrismataAI/bin/asset/config/cardLibrary.jso",
    )
    args = parser.parse_args()

    # Build manifest from extracted sprites
    manifest = build_manifest(args.output_dir)
    manifest_path = os.path.join(args.output_dir, "manifest.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"Manifest: {len(manifest)} units -> {manifest_path}")

    # Load card library
    card_library = {}
    if os.path.exists(args.card_library):
        with open(args.card_library, "r") as f:
            card_library = json.load(f)

    # Build descriptions
    unit_names = list(manifest.keys())
    descriptions = build_descriptions(unit_names, card_library)
    desc_path = os.path.join(args.output_dir, "descriptions.json")
    with open(desc_path, "w") as f:
        json.dump(descriptions, f, indent=2)
    print(f"Descriptions: {len(descriptions)} units -> {desc_path}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd tools/prismata_asset_prep && python -m pytest test_build_manifest.py -v`
Expected: All 4 tests PASS

- [ ] **Step 5: Commit**

```bash
git add tools/prismata_asset_prep/build_manifest.py tools/prismata_asset_prep/test_build_manifest.py
git commit -m "feat: add manifest and description builder for 3D pipeline"
```

---

### Task 5: Orchestrator and Full Run

**Files:**
- Create: `tools/prismata_asset_prep/run_all.py`

- [ ] **Step 1: Create the orchestrator**

```python
# tools/prismata_asset_prep/run_all.py
"""
Run all asset preparation steps in order.

1. Extract skins from .skin files
2. Extract first frame from animated .batch files (overrides existing)
3. Build manifest.json and descriptions.json

Usage:
  python run_all.py [--output-dir DIR]
"""
import os
import sys
import json
import argparse
from extract_skins import extract_all_skins
from extract_animated_frames import extract_all_animated
from build_manifest import build_manifest, build_descriptions


def main():
    parser = argparse.ArgumentParser(description="Prepare all Prismata assets for 3D pipeline")
    parser.add_argument("--output-dir", default="../../generated/prismata_3d_input")
    parser.add_argument("--skin-dir", default="C:/libraries/Prismata/newUnitArt")
    parser.add_argument("--anim-dir", default="C:/libraries/Prismata/animatedUnit")
    parser.add_argument("--sprite-dir", default="../../assets/card_sprites")
    parser.add_argument(
        "--card-library",
        default="C:/libraries/PrismataAI/bin/asset/config/cardLibrary.jso",
    )
    args = parser.parse_args()

    output_dir = os.path.abspath(args.output_dir)
    os.makedirs(output_dir, exist_ok=True)

    # Step 1: Extract skins
    print("=" * 60)
    print("Step 1: Extracting skins from .skin files")
    print("=" * 60)
    skin_units = extract_all_skins(args.skin_dir, args.sprite_dir, output_dir)
    skin_count = sum(len(v) for v in skin_units.values())
    print(f"  -> {skin_count} sprites for {len(skin_units)} units\n")

    # Step 2: Extract animated frames (overrides existing if same unit/skin)
    print("=" * 60)
    print("Step 2: Extracting animated skin frames")
    print("=" * 60)
    anim_units = extract_all_animated(args.anim_dir, output_dir)
    anim_count = sum(len(v) for v in anim_units.values())
    print(f"  -> {anim_count} animated frames for {len(anim_units)} units\n")

    # Step 3: Build manifest
    print("=" * 60)
    print("Step 3: Building manifest and descriptions")
    print("=" * 60)
    manifest = build_manifest(output_dir)
    with open(os.path.join(output_dir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)

    card_library = {}
    if os.path.exists(args.card_library):
        with open(args.card_library, "r") as f:
            card_library = json.load(f)

    descriptions = build_descriptions(list(manifest.keys()), card_library)
    with open(os.path.join(output_dir, "descriptions.json"), "w") as f:
        json.dump(descriptions, f, indent=2)

    # Summary
    total_skins = sum(len(v) for v in manifest.values())
    print(f"\n{'=' * 60}")
    print(f"DONE")
    print(f"  Units:       {len(manifest)}")
    print(f"  Total skins: {total_skins}")
    print(f"  Output:      {output_dir}")
    print(f"{'=' * 60}")

    # Validation: every unit should have at least a Regular skin
    missing_regular = [u for u, skins in manifest.items() if "Regular" not in skins]
    if missing_regular:
        print(f"\nWARNING: {len(missing_regular)} units missing Regular skin:")
        for u in missing_regular[:10]:
            print(f"  - {u}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Run the full pipeline**

Run: `cd tools/prismata_asset_prep && python run_all.py`
Expected: Completes with ~143 units and ~670+ total skins. Check for warnings about missing Regular skins.

- [ ] **Step 3: Validate output structure**

Run: `ls generated/prismata_3d_input/units/ | head -20`
Run: `ls generated/prismata_3d_input/units/drone/`
Run: `python -c "import json; m=json.load(open('generated/prismata_3d_input/manifest.json')); print(len(m), 'units'); print(sum(len(v) for v in m.values()), 'total skins')"`
Run: `python -c "import json; d=json.load(open('generated/prismata_3d_input/descriptions.json')); print(d.get('drone','MISSING')); print(d.get('engineer','MISSING'))"`

Expected: manifest.json has ~143 units, descriptions.json has matching entries, drone/engineer descriptions look reasonable.

- [ ] **Step 4: Run all tests one final time**

Run: `cd tools/prismata_asset_prep && python -m pytest -v`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add tools/prismata_asset_prep/run_all.py
git commit -m "feat: add asset preparation orchestrator for 3D model pipeline"
```

- [ ] **Step 6: Add generated output to .gitignore**

Add to the project root `.gitignore`:
```
# Generated asset prep output (large, rebuild from source)
generated/
```

```bash
git add .gitignore
git commit -m "chore: gitignore generated asset prep output"
```

---

### Task 6: Upload to S3

**Files:**
- Modify: `tools/prismata_asset_prep/run_all.py` (add S3 sync step)

This makes the prepared assets available for the AMI build and EC2 runtime.

- [ ] **Step 1: Add S3 upload to orchestrator**

Add to the end of `run_all.py`'s `main()`, before `return 0`:

```python
    # Step 4: Upload to S3
    print(f"\n{'=' * 60}")
    print(f"Step 4: Uploading to S3")
    print(f"{'=' * 60}")
    import subprocess
    bucket = "s3://prismata-3d-models/asset-prep/"
    result = subprocess.run(
        ["aws", "s3", "sync", output_dir, bucket, "--region", "us-east-1"],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        print(f"  -> Uploaded to {bucket}")
    else:
        print(f"  -> S3 upload failed (non-fatal): {result.stderr[:200]}")
        print(f"     You can manually sync later: aws s3 sync {output_dir} {bucket}")
```

- [ ] **Step 2: Create the S3 bucket**

Run: `aws s3 mb s3://prismata-3d-models --region us-east-1`

- [ ] **Step 3: Run the full pipeline with S3 upload**

Run: `cd tools/prismata_asset_prep && python run_all.py`
Expected: Steps 1-3 complete as before, Step 4 uploads to S3.

- [ ] **Step 4: Verify S3 contents**

Run: `aws s3 ls s3://prismata-3d-models/asset-prep/units/ --region us-east-1 | head -10`
Run: `aws s3 ls s3://prismata-3d-models/asset-prep/manifest.json --region us-east-1`
Expected: Unit directories and manifest.json visible in S3.

- [ ] **Step 5: Commit**

```bash
git add tools/prismata_asset_prep/run_all.py
git commit -m "feat: add S3 upload step to asset preparation pipeline"
```
