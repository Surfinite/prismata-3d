import os
import io
import struct
import tempfile
import pytest
from PIL import Image
from extract_animated_frames import extract_first_frame, extract_all_animated


def _make_sprite_sheet(cols: int, rows: int, frame_size: int = 300) -> bytes:
    """Create a sprite sheet PNG with colored frames."""
    width = cols * (frame_size + 2) + 1
    height = rows * (frame_size + 2) + 1
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
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
    """Build a .batch archive. Uses 60-byte name fields (matching real format)."""
    num = 2
    header = struct.pack("<I", num)
    toc = b""
    toc += b"animHD.png".ljust(60, b" ") + struct.pack("<I", len(png_data))
    toc += b"_animHD.xml".ljust(60, b" ") + struct.pack("<I", len(xml_data))
    return header + toc + png_data + xml_data


def test_extract_first_frame():
    png_data = _make_sprite_sheet(3, 2, frame_size=10)
    xml_data = _make_atlas_xml(3, 2, frame_size=10)
    archive = _make_batch_archive(png_data, xml_data)
    frame = extract_first_frame(archive)
    assert frame is not None
    assert frame.size == (10, 10)


def test_extract_all_animated():
    with tempfile.TemporaryDirectory() as anim_dir, \
         tempfile.TemporaryDirectory() as out_dir:
        os.makedirs(os.path.join(out_dir, "units"), exist_ok=True)
        png_data = _make_sprite_sheet(3, 2, frame_size=10)
        xml_data = _make_atlas_xml(3, 2, frame_size=10)
        archive = _make_batch_archive(png_data, xml_data)
        with open(os.path.join(anim_dir, "Erebos_Regular_large.batch"), "wb") as f:
            f.write(archive)

        result = extract_all_animated(anim_dir, out_dir)
        assert "erebos" in result
        assert os.path.exists(os.path.join(out_dir, "units", "erebos", "Regular.png"))
