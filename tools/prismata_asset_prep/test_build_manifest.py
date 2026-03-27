import os
import json
import tempfile
import pytest
from build_manifest import build_manifest, build_descriptions, generate_visual_description


def test_generate_visual_description_basic():
    desc = generate_visual_description("Drone", {"buyCost": "3H", "toughness": 1})
    assert "Drone" in desc or "drone" in desc.lower()
    assert isinstance(desc, str)
    assert len(desc) > 20


def test_generate_visual_description_unknown_unit():
    desc = generate_visual_description("MadeUpUnit", {})
    assert "MadeUpUnit" in desc


def test_build_manifest_from_directory():
    with tempfile.TemporaryDirectory() as out_dir:
        units_dir = os.path.join(out_dir, "units")
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
