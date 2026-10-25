"""Adds a Dolby Vision configuration record to an ffmpeg-written MP4 (design section 7.8).

Usage: python3 -I scripts/make-dovi.py <in.mp4> <out.mp4> --profile P --level L --compatibility C
                                       [--rpu 0|1] [--el 0|1] [--bl 0|1] [--sample-entry dvh1]

The record (dvcC for profiles up to 7, dvvC for 8 to 10, dvwC above) is appended to the HEVC
sample entry inside stsd, and every parent box size (the entry, stsd, stbl, minf, mdia, trak,
moov) grows by its length. The input must have moov after mdat, so no chunk offset moves.
--sample-entry renames the entry (hvc1 to dvh1 for profile 5). Standard library only.
"""

import argparse
import os
import struct
import sys

CONTAINERS = {b"moov", b"trak", b"mdia", b"minf", b"stbl"}
HEVC_ENTRIES = {b"hvc1", b"hev1"}
# VisualSampleEntry fields before its child boxes: 6 reserved, data_reference_index, 16 bytes
# pre_defined and reserved, width, height, resolutions, reserved, frame_count, compressorname,
# depth, pre_defined (ISO/IEC 14496-12).
VISUAL_SAMPLE_ENTRY_FIELDS = 78
STSD_HEADER = 8  # full box version and flags, entry_count


def record(profile, level, rpu, el, bl, compatibility):
    """DOVIDecoderConfigurationRecord: 24 bytes (Dolby Vision streams within ISO BMFF, 2.2)."""
    packed = (profile & 0x7F) << 9 | (level & 0x3F) << 3 | rpu << 2 | el << 1 | bl
    # Compatibility id in the top 4 bits of the next 32 bits; the rest is reserved.
    return struct.pack(">BBHI", 1, 0, packed, (compatibility & 0x0F) << 28) + bytes(16)


def box_name(profile):
    if profile <= 7:
        return b"dvcC"
    if profile <= 10:
        return b"dvvC"
    return b"dvwC"


def boxes(data, start, end):
    """(offset, size, type, header length) of each box between start and end."""
    pos = start
    while pos + 8 <= end:
        size, kind = struct.unpack_from(">I4s", data, pos)
        header = 8
        if size == 1:
            size = struct.unpack_from(">Q", data, pos + 8)[0]
            header = 16
        elif size == 0:
            size = end - pos
        if size < header or pos + size > end:
            raise ValueError(f"bad box {kind!r} at {pos}")
        yield pos, size, kind, header
        pos += size


def grow(data, offset, header, delta):
    if header == 16:
        size = struct.unpack_from(">Q", data, offset + 8)[0]
        struct.pack_into(">Q", data, offset + 8, size + delta)
    else:
        size = struct.unpack_from(">I", data, offset)[0]
        struct.pack_into(">I", data, offset, size + delta)


def find_entry(data, start, end, path):
    """The path of (offset, header) boxes from moov down to the HEVC sample entry."""
    for offset, size, kind, header in boxes(data, start, end):
        here = path + [(offset, header)]
        if kind in CONTAINERS:
            found = find_entry(data, offset + header, offset + size, here)
            if found:
                return found
        elif kind == b"stsd":
            for entry_offset, entry_size, entry_kind, entry_header in boxes(data, offset + header + STSD_HEADER, offset + size):
                if entry_kind in HEVC_ENTRIES:
                    return here + [(entry_offset, entry_header, entry_size)]
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("source")
    parser.add_argument("output")
    parser.add_argument("--profile", type=int, required=True)
    parser.add_argument("--level", type=int, required=True)
    parser.add_argument("--compatibility", type=int, required=True)
    parser.add_argument("--rpu", type=int, default=1, choices=(0, 1))
    parser.add_argument("--el", type=int, default=0, choices=(0, 1))
    parser.add_argument("--bl", type=int, default=1, choices=(0, 1))
    parser.add_argument("--sample-entry", default=None)
    args = parser.parse_args()

    with open(args.source, "rb") as source:
        data = bytearray(source.read())
    top = {kind: offset for offset, _, kind, _ in boxes(data, 0, len(data))}
    if b"moov" not in top or b"mdat" not in top:
        sys.exit("no moov or mdat box")
    if top[b"moov"] < top[b"mdat"]:
        sys.exit("moov is before mdat: chunk offsets would move")
    moov = next((o, s, h) for o, s, k, h in boxes(data, 0, len(data)) if k == b"moov")
    path = find_entry(data, moov[0], moov[0] + moov[1], [])
    if not path:
        sys.exit("no hvc1 or hev1 sample entry")
    entry_offset, entry_header, entry_size = path[-1]
    children = entry_offset + entry_header + VISUAL_SAMPLE_ENTRY_FIELDS
    existing = [kind for _, _, kind, _ in boxes(data, children, entry_offset + entry_size)]
    if any(kind in (b"dvcC", b"dvvC", b"dvwC") for kind in existing):
        sys.exit("the sample entry already has a Dolby Vision record")
    payload = record(args.profile, args.level, args.rpu, args.el, args.bl, args.compatibility)
    box = struct.pack(">I4s", 8 + len(payload), box_name(args.profile)) + payload
    insert_at = entry_offset + entry_size
    data[insert_at:insert_at] = box
    grow(data, entry_offset, entry_header, len(box))
    for offset, header in path[:-1]:
        grow(data, offset, header, len(box))
    if args.sample_entry:
        name = args.sample_entry.encode("ascii")
        if len(name) != 4:
            sys.exit("--sample-entry needs a four-character code")
        type_offset = entry_offset + 4
        data[type_offset:type_offset + 4] = name

    tmp = args.output + ".partial"
    with open(tmp, "wb") as out:
        out.write(data)
    os.replace(tmp, args.output)


if __name__ == "__main__":
    main()
