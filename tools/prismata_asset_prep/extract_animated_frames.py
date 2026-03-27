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
        return sheet.crop((0, 0, min(300, sheet.width), min(300, sheet.height)))

    xml_text = xml_entry.data.decode("utf-8", errors="replace")
    root = ET.fromstring(xml_text)
    for sub in root.findall("SubTexture"):
        if sub.get("name") == "00":
            x = int(sub.get("x", 0))
            y = int(sub.get("y", 0))
            w = int(sub.get("width", 300))
            h = int(sub.get("height", 300))
            return sheet.crop((x, y, x + w, y + h))

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


def extract_all_animated(anim_dir: str, output_dir: str) -> dict[str, list[str]]:
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
