#!/usr/bin/env python3
import hashlib
import struct
import sys
from pathlib import Path

MAGIC = 0xD7B7AB1E
EXPECTED_ORDER = ("GRAM", "EXCALIBUR", "JOYEUSE", "CURTANA")
EXPECTED_SHA256 = "70527ec48566ecf0f12da13b2ba254c65c2ea6d1d2e930d8891c3cdb60adbe65"


def die(msg):
    raise SystemExit(f"[dtbo-order] {msg}")


def board_name(blob):
    found = [name for name in EXPECTED_ORDER if name.encode() in blob]
    if len(found) != 1:
        die(f"could not uniquely identify overlay board; matches={found}")
    return found[0]


def main():
    if len(sys.argv) != 2:
        die(f"usage: {Path(sys.argv[0]).name} <dtbo.img>")

    path = Path(sys.argv[1])
    data = path.read_bytes()
    if len(data) < 32:
        die("DTBO image is shorter than the Android header")

    magic, total_size, header_size, entry_size, entry_count, entries_offset, page_size, version = struct.unpack(
        ">8I", data[:32]
    )
    if magic != MAGIC:
        die(f"unexpected magic 0x{magic:08x}")
    if total_size != len(data):
        die(f"header total_size={total_size}, actual={len(data)}")
    if header_size != 32 or entry_size < 32 or entry_count != 4:
        die(
            f"unexpected table layout header={header_size} entry={entry_size} count={entry_count}"
        )
    table_end = entries_offset + entry_size * entry_count
    if entries_offset < header_size or table_end > len(data):
        die("entry table lies outside image")

    entries = []
    for idx in range(entry_count):
        start = entries_offset + idx * entry_size
        raw = data[start : start + entry_size]
        dt_size, dt_offset, ident, rev, c0, c1, c2, c3 = struct.unpack(">8I", raw[:32])
        end = dt_offset + dt_size
        if dt_offset < table_end or end > len(data):
            die(f"entry {idx} payload is outside image")
        blob = data[dt_offset:end]
        entries.append(
            {
                "board": board_name(blob),
                "size": dt_size,
                "meta": (ident, rev, c0, c1, c2, c3),
                "extra": raw[32:],
                "blob": blob,
            }
        )

    by_board = {entry["board"]: entry for entry in entries}
    if len(by_board) != len(EXPECTED_ORDER) or set(by_board) != set(EXPECTED_ORDER):
        die(f"unexpected board set/order: {[entry['board'] for entry in entries]}")

    before = tuple(entry["board"] for entry in entries)
    first_payload = min(
        struct.unpack(">I", data[entries_offset + i * entry_size + 4 : entries_offset + i * entry_size + 8])[0]
        for i in range(entry_count)
    )
    prefix_gap = data[table_end:first_payload]
    max_payload_end = max(
        struct.unpack(">I", data[entries_offset + i * entry_size + 4 : entries_offset + i * entry_size + 8])[0]
        + struct.unpack(">I", data[entries_offset + i * entry_size : entries_offset + i * entry_size + 4])[0]
        for i in range(entry_count)
    )
    tail = data[max_payload_end:]

    out = bytearray(data[:entries_offset])
    payload_offset = table_end + len(prefix_gap)
    table = bytearray()
    payload = bytearray(prefix_gap)

    for board in EXPECTED_ORDER:
        entry = by_board[board]
        table += struct.pack(
            ">8I",
            entry["size"],
            payload_offset,
            *entry["meta"],
        )
        table += entry["extra"]
        payload += entry["blob"]
        payload_offset += entry["size"]

    out += table
    out += payload
    out += tail
    if len(out) != len(data):
        die(f"repacked size changed from {len(data)} to {len(out)}")

    # total_size is unchanged, but rewrite it from the actual output for safety.
    out[4:8] = struct.pack(">I", len(out))
    digest = hashlib.sha256(out).hexdigest()
    if digest != EXPECTED_SHA256:
        die(
            "reordered DTBO does not match workflow #187 known-good binary: "
            f"got {digest}, expected {EXPECTED_SHA256}"
        )

    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_bytes(out)
    tmp.replace(path)
    print(f"[dtbo-order] {before} -> {EXPECTED_ORDER}")
    print(f"[dtbo-order] exact r187 DTBO restored: sha256={digest}")
    print(f"[dtbo-order] page_size={page_size} version={version}")


if __name__ == "__main__":
    main()
