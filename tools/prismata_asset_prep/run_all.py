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
