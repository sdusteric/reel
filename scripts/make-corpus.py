"""Writes the damaged-file corpus (design section 7.10) next to its base files.

Usage: python3 -I scripts/make-corpus.py --ffprobe <path> <corpus dir> <base file>...

Each base file <name>.<ext> in <corpus dir> gets these copies, named <name>.<mutation>.<ext>:
truncations to 1, 10, 50 and 90% of the bytes, the first 4 KB only, a 4 KB random overwrite at
25, 50 and 75%, bit flips at a rate of 1e-4 with seeds 1, 2 and 3, the middle 10% filled with
zeros, and the two halves swapped. manifest.json lists every file (bases too) with its base,
mutation, expected outcome ('played', 'classified' or 'any'), the damaged byte range and
whether it holds video or audio packets, and for truncated faststart MP4 and Matroska files the
expected dataEnd in seconds, from the base's packets as ffprobe reports them. Seeds are fixed,
so the corpus is the same on every run. Standard library only (ffprobe runs as a subprocess).
"""

import argparse
import json
import math
import os
import random
import subprocess
import sys

TRUNCATIONS = [1, 10, 50, 90]
OVERWRITES = [25, 50, 75]
FLIP_SEEDS = [1, 2, 3]
FLIP_RATE = 1e-4
CHUNK = 4096


def probe(ffprobe, path):
    """Packets (stream kind, pts seconds, end pts seconds, byte range) and the duration."""
    output = subprocess.run(
        [ffprobe, "-v", "error", "-show_entries",
         "packet=stream_index,pts_time,dts_time,duration_time,pos,size:stream=index,codec_type:format=duration,format_name",
         "-of", "json", path],
        check=True, capture_output=True, text=True,
    ).stdout
    data = json.loads(output)
    kinds = {stream["index"]: stream["codec_type"] for stream in data["streams"]}
    packets = []
    for packet in data.get("packets", []):
        pos = packet.get("pos")
        time = packet.get("pts_time", packet.get("dts_time"))
        if pos is None or time is None or time == "N/A":
            continue
        start = float(time)
        duration = float(packet.get("duration_time", 0) or 0)
        packets.append({
            "kind": kinds.get(packet["stream_index"], "data"),
            "time": start,
            "end": start + duration,
            "pos": int(pos),
            "stop": int(pos) + int(packet["size"]),
        })
    fmt = data["format"]
    return packets, float(fmt.get("duration", 0) or 0), fmt.get("format_name", "")


def family(name, format_name):
    if name.endswith(".mp4") and "faststart" in name:
        return "mp4-faststart"
    if name.endswith(".mp4"):
        return "mp4-moov-end"
    if "matroska" in format_name:
        return "matroska"
    return "other"


def data_end(packets, cut):
    """The last video presentation time whose packet lies wholly before byte `cut`."""
    times = [p["time"] for p in packets if p["kind"] == "video" and p["stop"] <= cut]
    return round(max(times), 3) if times else None


def region(packets, start, stop):
    hit = [p for p in packets if p["pos"] < stop and p["stop"] > start]
    return {"start": start, "end": stop,
            "video": any(p["kind"] == "video" for p in hit),
            "audio": any(p["kind"] == "audio" for p in hit)}


def flip_bits(data, seed):
    """Flips each bit with probability FLIP_RATE, by geometric gaps between flips."""
    rng = random.Random(seed)
    out = bytearray(data)
    bits = len(out) * 8
    position = -1
    flipped = 0
    while True:
        gap = int(math.log(1 - rng.random()) / math.log(1 - FLIP_RATE))
        position += gap + 1
        if position >= bits:
            return out, flipped
        out[position // 8] ^= 1 << (position % 8)
        flipped += 1


def write(path, data):
    tmp = os.path.join(os.path.dirname(path), ".partial-" + os.path.basename(path))
    with open(tmp, "wb") as out:
        out.write(data)
    os.replace(tmp, path)


def mutations(base_index, data, packets, kind):
    """(mutation, bytes, entry fields) for one base."""
    size = len(data)
    first_packet = min((p["pos"] for p in packets), default=0)
    last_packet = max((p["stop"] for p in packets), default=size)
    has_video = any(p["kind"] == "video" for p in packets)
    result = []

    for percent in TRUNCATIONS:
        cut = size * percent // 100
        fields = {"truncatedTo": cut, "expected": "any"}
        if kind == "mp4-moov-end":
            fields["expected"] = "classified"
        elif kind in ("mp4-faststart", "matroska") and percent >= 10:
            end = data_end(packets, cut)
            if end is not None and cut > first_packet:
                fields["expected"] = "played"
                fields["dataEnd"] = end
        result.append((f"trunc{percent:02d}", data[:cut], fields))

    # A known header with no whole packet after it is cut short; otherwise anything may happen.
    whole_packet = any(p["stop"] <= CHUNK for p in packets)
    head = {"truncatedTo": CHUNK, "expected": "classified" if kind != "other" and not whole_packet else "any"}
    result.append(("head4k", data[:CHUNK], head))

    for percent in OVERWRITES:
        start = size * percent // 100
        stop = min(start + CHUNK, size)
        rng = random.Random(1000 * (base_index + 1) + percent)
        damaged = bytearray(data)
        damaged[start:stop] = bytes(rng.getrandbits(8) for _ in range(stop - start))
        inside = first_packet <= start and stop <= last_packet
        fields = {"damage": region(packets, start, stop), "expected": "played" if inside and has_video else "any"}
        result.append((f"overwrite{percent}", bytes(damaged), fields))

    for seed in FLIP_SEEDS:
        flipped, count = flip_bits(data, seed)
        result.append((f"bitflip{seed}", bytes(flipped), {"seed": seed, "flippedBits": count, "expected": "any"}))

    start = size * 45 // 100
    stop = size * 55 // 100
    zeroed = bytearray(data)
    zeroed[start:stop] = bytes(stop - start)
    inside = first_packet <= start and stop <= last_packet
    result.append(("zeromid", bytes(zeroed), {"damage": region(packets, start, stop),
                                              "expected": "played" if inside and has_video else "any"}))

    half = size // 2
    result.append(("swapped", data[half:] + data[:half], {"expected": "any"}))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ffprobe", required=True)
    parser.add_argument("corpus")
    parser.add_argument("bases", nargs="+")
    args = parser.parse_args()

    entries = []
    for index, base_path in enumerate(args.bases):
        name = os.path.basename(base_path)
        stem, ext = os.path.splitext(name)
        packets, duration, format_name = probe(args.ffprobe, base_path)
        if not packets:
            sys.exit(f"ffprobe found no packets in {base_path}")
        kind = family(name, format_name)
        with open(base_path, "rb") as source:
            data = source.read()
        common = {"base": name, "baseDuration": round(duration, 3), "family": kind, "baseBytes": len(data)}
        entries.append({"file": name, "mutation": "none", "expected": "played", **common})
        for mutation, content, fields in mutations(index, data, packets, kind):
            file_name = f"{stem}.{mutation}{ext}"
            write(os.path.join(args.corpus, file_name), content)
            entries.append({"file": file_name, "mutation": mutation, **common, **fields})

    manifest = {
        "version": 1,
        "truncations": TRUNCATIONS,
        "overwrites": OVERWRITES,
        "flipSeeds": FLIP_SEEDS,
        "flipRate": FLIP_RATE,
        "files": sorted(entries, key=lambda entry: entry["file"]),
    }
    path = os.path.join(args.corpus, "manifest.json")
    tmp = os.path.join(args.corpus, ".partial-manifest.json")
    with open(tmp, "w", encoding="utf-8") as out:
        json.dump(manifest, out, indent=2, sort_keys=True, ensure_ascii=False)
        out.write("\n")
    os.replace(tmp, path)


if __name__ == "__main__":
    main()
