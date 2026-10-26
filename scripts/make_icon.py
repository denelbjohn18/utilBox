#!/usr/bin/env python3
"""Draw resources/AppIcon.iconset. The Mac build turns it into utilBox.icns.

The glyph matches the mailbox reference: charcoal on a light gray field,
arched door, flag, and a short post toward the right.
"""

import struct
import zlib
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "resources" / "AppIcon.iconset"

# Measured from the reference image, in that image's pixel space.
REF = 554.0
BODY = (153.0, 222.0, 247.0, 146.0, 44.0)
DOOR_CIRCLE = (204.0, 278.0, 40.0)
DOOR_BOX = (164.0, 278.0, 80.0, 74.0)
FLAG = (286.0, 154.0, 68.0, 34.0, 6.0)
POLE = (288.0, 168.0, 12.0, 70.0)
POST = (331.0, 362.0, 26.0, 38.0, 2.0)
INK = np.array([59, 59, 59], dtype=np.float64)
FIELD = np.array([244, 244, 244], dtype=np.float64)


def write_png(path: Path, rgba: np.ndarray) -> None:
    height, width, channels = rgba.shape
    if channels != 4:
        raise SystemExit("expected RGBA")
    raw = b"".join(b"\x00" + rgba[y].tobytes() for y in range(height))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


def sd_round_box(px, py, x, y, width, height, radius):
    cx = x + width / 2
    cy = y + height / 2
    qx = np.abs(px - cx) - width / 2 + radius
    qy = np.abs(py - cy) - height / 2 + radius
    ax = np.maximum(qx, 0)
    ay = np.maximum(qy, 0)
    return np.minimum(np.maximum(qx, qy), 0) + np.sqrt(ax * ax + ay * ay) - radius


def sd_box(px, py, x, y, width, height):
    cx = x + width / 2
    cy = y + height / 2
    dx = np.abs(px - cx) - width / 2
    dy = np.abs(py - cy) - height / 2
    ax = np.maximum(dx, 0)
    ay = np.maximum(dy, 0)
    return np.sqrt(ax * ax + ay * ay) + np.minimum(np.maximum(dx, dy), 0)


def sd_circle(px, py, cx, cy, radius):
    return np.sqrt((px - cx) ** 2 + (py - cy) ** 2) - radius


def mailbox_distance(px, py):
    body = sd_round_box(px, py, *BODY)
    door = np.minimum(sd_circle(px, py, *DOOR_CIRCLE), sd_box(px, py, *DOOR_BOX))
    flag = sd_round_box(px, py, *FLAG)
    pole = sd_box(px, py, *POLE)
    post = sd_round_box(px, py, *POST)
    shape = np.minimum(np.minimum(body, flag), np.minimum(pole, post))
    return np.maximum(shape, -door)


def render(size: int) -> np.ndarray:
    samples = 8 if size <= 64 else 4
    canvas = size * samples
    ys, xs = np.mgrid[0:canvas, 0:canvas]
    # Large sizes keep the reference's wide margin. Small sizes enlarge the glyph so it still reads.
    if size <= 32:
        scale = 248.0 / (0.82 * canvas)
        center = 277.0
        px = (xs.astype(np.float64) + 0.5 - canvas / 2) * scale + center
        py = (ys.astype(np.float64) + 0.5 - canvas / 2) * scale + center
        softness = scale * 0.7
    else:
        px = (xs.astype(np.float64) + 0.5) * REF / canvas
        py = (ys.astype(np.float64) + 0.5) * REF / canvas
        softness = REF / canvas
    coverage = np.clip(0.5 - mailbox_distance(px, py) / max(softness, 0.75), 0, 1)
    image = np.zeros((canvas, canvas, 4), dtype=np.float64)
    image[..., :3] = FIELD + (INK - FIELD) * coverage[..., None]
    image[..., 3] = 255
    image = image.reshape(size, samples, size, samples, 4).mean(axis=(1, 3))
    return np.clip(np.rint(image), 0, 255).astype(np.uint8)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    sizes = {
        "icon_16x16.png": 16,
        "icon_16x16@2x.png": 32,
        "icon_32x32.png": 32,
        "icon_32x32@2x.png": 64,
        "icon_128x128.png": 128,
        "icon_128x128@2x.png": 256,
        "icon_256x256.png": 256,
        "icon_256x256@2x.png": 512,
        "icon_512x512.png": 512,
        "icon_512x512@2x.png": 1024,
    }
    for name, size in sizes.items():
        write_png(OUT / name, render(size))
        print(f"wrote {name}")


if __name__ == "__main__":
    main()
