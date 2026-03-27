"""
Parser for Prismata .skin and .batch archive format.

Format:
  [4 bytes] num_files (uint32 LE)
  [repeat num_files]:
    [60 bytes] filename (ASCII, space-padded)
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
        raw_name = data[offset : offset + 60]
        name = raw_name.split(b"\x00")[0].rstrip(b" ").decode("ascii", errors="replace")
        offset += 60
        size = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        toc.append((name, size))

    entries: list[ArchiveEntry] = []
    for name, size in toc:
        entries.append(ArchiveEntry(name=name, data=data[offset : offset + size]))
        offset += size

    return entries
