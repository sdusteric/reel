"""Writes one raw frame of the HDR and SDR patch ramps (design section 7.7) and their expected codes.

Usage: python3 -I scripts/make-ramp.py <pq|hlg|sdr> <frame.yuv> <ramps.json>
       python3 -I scripts/make-ramp.py strip-mkv-colour <file.mkv>
       python3 -I scripts/make-ramp.py verify <pq|hlg|sdr> <decoded frame.yuv> <ramps.json> <tolerance>

pq and hlg write yuv420p10le, sdr writes yuv420p (8-bit), all 1920x1080 limited range. Each frame
is a row of flat neutral patches at known levels on black, and below it three primaries at
reference white (203 nits PQ, HLG signal 0.75, SDR signal 0.75). ramps.json is merged: the
entry for this transfer is replaced and the others are kept. Standard library only.

strip-mkv-colour overwrites every video track's Matroska Colour element (primaries, transfer,
matrix, range, mastering metadata) with an EBML Void element of the same length, in place, so
no offset in the file moves. The AV1 ramp uses it: its colour then comes only from the bitstream.

verify reads one decoded frame (the pixel format of the ramp) and checks the Y, Cb and Cr code at
each patch centre against ramps.json, within <tolerance> codes.
"""

import json
import os
import struct
import sys

WIDTH = 1920
HEIGHT = 1080

# PQ (SMPTE ST 2084) constants.
M1 = 2610 / 16384
M2 = 2523 / 4096 * 128
C1 = 3424 / 4096
C2 = 2413 / 4096 * 32
C3 = 2392 / 4096 * 32

PQ_NITS = [0, 0.1, 1, 10, 100, 203, 400, 1000, 4000, 10000]
HLG_SIGNALS = [0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0]
SDR_SIGNALS = [0, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0]
REFERENCE_NITS = 203
HLG_REFERENCE = 0.75
SDR_REFERENCE = 0.75

# Luma coefficients (Kr, Kb): BT.2020 non-constant luminance and BT.709.
KR_KB = {"bt2020": (0.2627, 0.0593), "bt709": (0.2126, 0.0722)}

NEUTRAL_TOP = 128
NEUTRAL_HEIGHT = 384
PRIMARY_TOP = 640
PRIMARY_HEIGHT = 320
PRIMARY_WIDTH = 384


def pq_signal(nits):
    """Inverse EOTF: absolute luminance to the PQ signal, 0 to 1."""
    y = max(nits, 0) / 10000
    p = y ** M1
    return ((C1 + C2 * p) / (1 + C3 * p)) ** M2


def to_codes(r, g, b, kr, kb, bits):
    """Non-linear R'G'B' (0 to 1) to limited-range Y'CbCr codes."""
    kg = 1 - kr - kb
    y = kr * r + kg * g + kb * b
    cb = (b - y) / (2 * (1 - kb))
    cr = (r - y) / (2 * (1 - kr))
    scale = 1 << (bits - 8)
    y_code = round((16 + 219 * y) * scale)
    cb_code = round((128 + 224 * cb) * scale)
    cr_code = round((128 + 224 * cr) * scale)
    low = 16 * scale
    return (
        min(max(y_code, low), 235 * scale),
        min(max(cb_code, low), 240 * scale),
        min(max(cr_code, low), 240 * scale),
    )


def neutral_rects(count):
    """Equal patches across the frame, each a multiple of 16 wide, centred."""
    width = (WIDTH // count) // 16 * 16
    left = (WIDTH - width * count) // 2
    return [(left + i * width, NEUTRAL_TOP, width, NEUTRAL_HEIGHT) for i in range(count)]


def primary_rects():
    gap = (WIDTH - 3 * PRIMARY_WIDTH) // 4
    return [(gap + i * (PRIMARY_WIDTH + gap), PRIMARY_TOP, PRIMARY_WIDTH, PRIMARY_HEIGHT) for i in range(3)]


def patches(transfer):
    if transfer == "pq":
        matrix, bits = "bt2020", 10
        neutral = [(f"{n:g} nits", {"nits": n}, pq_signal(n)) for n in PQ_NITS]
        white, black = pq_signal(REFERENCE_NITS), pq_signal(0)
    elif transfer == "hlg":
        matrix, bits = "bt2020", 10
        neutral = [(f"signal {s:g}", {"signal": s}, s) for s in HLG_SIGNALS]
        white, black = HLG_REFERENCE, 0.0
    else:
        matrix, bits = "bt709", 8
        neutral = [(f"signal {s:g}", {"signal": s}, s) for s in SDR_SIGNALS]
        white, black = SDR_REFERENCE, 0.0
    kr, kb = KR_KB[matrix]
    result = []
    for (name, level, signal), rect in zip(neutral, neutral_rects(len(neutral))):
        result.append({"name": name, "kind": "neutral", **level, "rect": rect, "rgb": [signal] * 3,
                       "codes": to_codes(signal, signal, signal, kr, kb, bits)})
    for (name, rgb), rect in zip(
        [("red", (white, black, black)), ("green", (black, white, black)), ("blue", (black, black, white))],
        primary_rects(),
    ):
        result.append({"name": name, "kind": "primary", "rect": rect, "rgb": list(rgb),
                       "codes": to_codes(*rgb, kr, kb, bits)})
    return matrix, bits, result


def write_frame(path, bits, items):
    scale = 1 << (bits - 8)
    black = (16 * scale, 128 * scale, 128 * scale)
    luma = [black[0]] * (WIDTH * HEIGHT)
    cw, ch = WIDTH // 2, HEIGHT // 2
    cb = [black[1]] * (cw * ch)
    cr = [black[2]] * (cw * ch)
    for item in items:
        x, y, w, h = item["rect"]
        yc, cbc, crc = item["codes"]
        for row in range(y, y + h):
            start = row * WIDTH
            luma[start + x:start + x + w] = [yc] * w
        for row in range(y // 2, (y + h) // 2):
            start = row * cw
            cb[start + x // 2:start + (x + w) // 2] = [cbc] * (w // 2)
            cr[start + x // 2:start + (x + w) // 2] = [crc] * (w // 2)
    fmt = "<{}H" if bits > 8 else "<{}B"
    tmp = path + ".partial"
    with open(tmp, "wb") as out:
        for plane in (luma, cb, cr):
            out.write(struct.pack(fmt.format(len(plane)), *plane))
    os.replace(tmp, path)


# Matroska element ids (with their length marker bits), from the Matroska specification.
EBML_SEGMENT = 0x18538067
EBML_TRACKS = 0x1654AE6B
EBML_TRACK_ENTRY = 0xAE
EBML_VIDEO = 0xE0
EBML_COLOUR = 0x55B0
EBML_VOID = 0xEC


def read_vint(data, pos, keep_marker):
    """An EBML variable-length integer at pos: (value, length). Unknown sizes return None."""
    first = data[pos]
    length = 1
    while length <= 8 and not first & (0x80 >> (length - 1)):
        length += 1
    if length > 8:
        raise ValueError(f"bad EBML vint at {pos}")
    value = first if keep_marker else first & (0xFF >> length)
    for byte in data[pos + 1:pos + length]:
        value = (value << 8) | byte
    if not keep_marker and value == (1 << (7 * length)) - 1:
        return None, length
    return value, length


def strip_mkv_colour(path):
    with open(path, "rb") as source:
        data = bytearray(source.read())
    stripped = 0

    def walk(start, end, wanted):
        nonlocal stripped
        pos = start
        while pos < end:
            element_id, id_length = read_vint(data, pos, True)
            size, size_length = read_vint(data, pos + id_length, False)
            body = pos + id_length + size_length
            stop = end if size is None else body + size
            if element_id == EBML_COLOUR and wanted == EBML_COLOUR:
                total = stop - pos
                if total < 9:
                    raise ValueError("Colour element too small to void")
                # Void id, an 8-byte size, then zeros: the same length as the Colour element.
                data[pos:stop] = bytes([EBML_VOID, 0x01]) + (total - 9).to_bytes(7, "big") + bytes(total - 9)
                stripped += 1
            elif element_id == wanted:
                child = {EBML_SEGMENT: EBML_TRACKS, EBML_TRACKS: EBML_TRACK_ENTRY,
                         EBML_TRACK_ENTRY: EBML_VIDEO, EBML_VIDEO: EBML_COLOUR}[wanted]
                walk(body, stop, child)
            pos = stop

    walk(0, len(data), EBML_SEGMENT)
    if stripped == 0:
        sys.exit(f"no Colour element in {path}")
    tmp = path + ".partial"
    with open(tmp, "wb") as out:
        out.write(data)
    os.replace(tmp, path)


def verify(transfer, frame_path, json_path, tolerance):
    with open(json_path, encoding="utf-8") as source:
        ramp = json.load(source)[transfer]
    with open(frame_path, "rb") as source:
        frame = source.read()
    sample = 2 if ramp["bitDepth"] > 8 else 1
    width, height = ramp["width"], ramp["height"]
    if len(frame) != width * height * 3 // 2 * sample:
        sys.exit(f"{frame_path}: {len(frame)} bytes is not one {width}x{height} frame")
    fmt = "<H" if sample == 2 else "<B"
    chroma = width * height * sample
    failures = []
    for patch in ramp["patches"]:
        x = patch["rect"]["x"] + patch["rect"]["w"] // 2
        y = patch["rect"]["y"] + patch["rect"]["h"] // 2
        got = (
            struct.unpack_from(fmt, frame, (y * width + x) * sample)[0],
            struct.unpack_from(fmt, frame, chroma + ((y // 2) * (width // 2) + x // 2) * sample)[0],
            struct.unpack_from(fmt, frame, chroma * 5 // 4 + ((y // 2) * (width // 2) + x // 2) * sample)[0],
        )
        want = (patch["codes"]["y"], patch["codes"]["cb"], patch["codes"]["cr"])
        if any(abs(a - b) > tolerance for a, b in zip(got, want)):
            failures.append(f"{patch['name']}: got {got}, want {want}")
    if failures:
        sys.exit("\n".join(failures))


def main():
    if len(sys.argv) == 6 and sys.argv[1] == "verify":
        verify(sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]))
        return
    if len(sys.argv) == 3 and sys.argv[1] == "strip-mkv-colour":
        strip_mkv_colour(sys.argv[2])
        return
    if len(sys.argv) != 4 or sys.argv[1] not in ("pq", "hlg", "sdr"):
        sys.exit("usage: make-ramp.py <pq|hlg|sdr> <frame.yuv> <ramps.json>")
    transfer, frame_path, json_path = sys.argv[1:]
    matrix, bits, items = patches(transfer)
    write_frame(frame_path, bits, items)
    ramps = {}
    if os.path.exists(json_path):
        with open(json_path, encoding="utf-8") as existing:
            ramps = json.load(existing)
    ramps[transfer] = {
        "width": WIDTH,
        "height": HEIGHT,
        "bitDepth": bits,
        "matrix": matrix,
        "range": "limited",
        "pixelFormat": "yuv420p10le" if bits > 8 else "yuv420p",
        "referenceWhite": {"pq": {"nits": REFERENCE_NITS}, "hlg": {"signal": HLG_REFERENCE},
                           "sdr": {"signal": SDR_REFERENCE}}[transfer],
        "patches": [{**item, "rect": dict(zip(("x", "y", "w", "h"), item["rect"])),
                     "codes": dict(zip(("y", "cb", "cr"), item["codes"]))} for item in items],
    }
    tmp = json_path + ".partial"
    with open(tmp, "w", encoding="utf-8") as out:
        json.dump(ramps, out, indent=2, sort_keys=True)
        out.write("\n")
    os.replace(tmp, json_path)


if __name__ == "__main__":
    main()
