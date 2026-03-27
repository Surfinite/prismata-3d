import struct
import os
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
        padded = name_bytes.ljust(60, b" ")
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
    assert result[0].name == "padded.png"


SKIN_PATH = "C:/libraries/Prismata/newUnitArt/Drone_Regular_all.skin"

@pytest.mark.skipif(not os.path.exists(SKIN_PATH), reason="Prismata not installed")
def test_parse_real_skin_file():
    with open(SKIN_PATH, "rb") as f:
        data = f.read()
    entries = parse_batch_archive(data)
    assert len(entries) == 6
    names = [e.name for e in entries]
    assert any("infoHD" in n for n in names)
    for e in entries:
        if e.name.endswith(".png"):
            assert e.data[:4] == b"\x89PNG", f"{e.name} is not a valid PNG"
