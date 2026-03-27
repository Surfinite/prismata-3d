"""
Build manifest.json and descriptions.json for the 3D model generation pipeline.

manifest.json: {unit_name: {skin_name: relative_path_to_png}}
descriptions.json: {unit_name: "text description for 3D generation"}

Usage:
  python build_manifest.py [--output-dir DIR] [--card-library PATH]
"""
import os
import json
import argparse

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
    unit_key = unit_display_name.replace(" ", "_").lower()

    if unit_key in KNOWN_VISUALS:
        base = KNOWN_VISUALS[unit_key]
    else:
        base = f"{unit_display_name}, a sci-fi strategy game unit"

    rarity = card_data.get("rarity", "normal")
    role = ROLE_HINTS.get(rarity, "combat unit")

    return f"{base}. Prismata {role}, stylized game asset, low-poly 3D model"


def build_manifest(output_dir: str) -> dict[str, dict[str, str]]:
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
    descriptions: dict[str, str] = {}

    card_lookup: dict[str, tuple[str, dict]] = {}
    for card_name, card_data in card_library.items():
        display = card_data.get("UIName", card_name)
        key = card_name.replace(" ", "_").lower()
        card_lookup[key] = (display, card_data)
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

    manifest = build_manifest(args.output_dir)
    manifest_path = os.path.join(args.output_dir, "manifest.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"Manifest: {len(manifest)} units -> {manifest_path}")

    card_library = {}
    if os.path.exists(args.card_library):
        with open(args.card_library, "r") as f:
            card_library = json.load(f)

    unit_names = list(manifest.keys())
    descriptions = build_descriptions(unit_names, card_library)
    desc_path = os.path.join(args.output_dir, "descriptions.json")
    with open(desc_path, "w") as f:
        json.dump(descriptions, f, indent=2)
    print(f"Descriptions: {len(descriptions)} units -> {desc_path}")


if __name__ == "__main__":
    main()
