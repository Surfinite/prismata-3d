"""
Extract best-quality sprite from each Prismata .skin archive file.

Preference order: infoHD (300x300) > largest PNG > any PNG.
Also copies base card sprites for units without .skin files.

Usage:
  python extract_skins.py [--skin-dir DIR] [--sprite-dir DIR] [--output-dir DIR]
"""
import os
import io
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

    for name, img in png_entries:
        if "infoHD" in name:
            return img.convert("RGBA")

    png_entries.sort(key=lambda x: x[1].size[0] * x[1].size[1], reverse=True)
    return png_entries[0][1].convert("RGBA")


def _parse_skin_filename(filename: str) -> tuple[str, str] | None:
    """Parse 'Unit Name_SkinName_all.skin' -> (unit_name, skin_name).
    Returns snake_case unit name and original skin name.
    """
    basename = filename.replace("_all.skin", "")
    parts = basename.rsplit("_", 1)
    if len(parts) != 2:
        return None
    unit_raw, skin_name = parts
    unit_name = unit_raw.replace(" ", "_").lower()
    return unit_name, skin_name


def extract_all_skins(
    skin_dir: str,
    base_sprite_dir: str,
    output_dir: str,
) -> dict[str, list[str]]:
    """Extract all skins, return {unit_name: [skin_names]} mapping."""
    units: dict[str, list[str]] = {}
    units_dir = os.path.join(output_dir, "units")

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

    if base_sprite_dir and os.path.isdir(base_sprite_dir):
        for sprite_file in sorted(os.listdir(base_sprite_dir)):
            if not sprite_file.endswith(".png"):
                continue
            unit_name = sprite_file.replace(".png", "")
            if unit_name in units and "Regular" in units[unit_name]:
                continue

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
