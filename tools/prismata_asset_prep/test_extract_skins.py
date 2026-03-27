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
        padded = name.encode("ascii").ljust(60, b" ")
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
        archive = _make_skin_archive({
            "Drone_Regular_infoHD.png": (300, 300),
        })
        with open(os.path.join(skin_dir, "Drone_Regular_all.skin"), "wb") as f:
            f.write(archive)

        base_img = Image.new("RGBA", (128, 128), (0, 255, 0, 255))
        base_img.save(os.path.join(sprite_dir, "barrier_forge.png"))

        result = extract_all_skins(
            skin_dir=skin_dir,
            base_sprite_dir=sprite_dir,
            output_dir=out_dir,
        )
        assert os.path.exists(os.path.join(out_dir, "units", "drone", "Regular.png"))
        assert os.path.exists(os.path.join(out_dir, "units", "barrier_forge", "Regular.png"))
        assert "drone" in result
        assert "barrier_forge" in result
