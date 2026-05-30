#!/usr/bin/env python3
import json
import math
import os
import struct
import sys
import zlib


def paeth(a, b, c):
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def decode_png(path):
    with open(path, "rb") as file:
        data = file.read()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("not a PNG")

    offset = 8
    width = height = color_type = bit_depth = None
    compressed = bytearray()
    while offset < len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        chunk_type = data[offset + 4:offset + 8]
        chunk_data = data[offset + 8:offset + 8 + length]
        offset += 12 + length
        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type, compression, filter_method, interlace = struct.unpack(
                ">IIBBBBB",
                chunk_data
            )
            if bit_depth != 8 or compression != 0 or filter_method != 0 or interlace != 0:
                raise ValueError("unsupported PNG encoding")
        elif chunk_type == b"IDAT":
            compressed.extend(chunk_data)
        elif chunk_type == b"IEND":
            break

    if width is None or height is None or color_type is None:
        raise ValueError("missing PNG header")

    channels_by_type = {0: 1, 2: 3, 4: 2, 6: 4}
    channels = channels_by_type.get(color_type)
    if channels is None:
        raise ValueError(f"unsupported color type {color_type}")

    raw = zlib.decompress(bytes(compressed))
    stride = width * channels
    rows = []
    pos = 0
    previous = bytearray(stride)
    for _ in range(height):
        filter_type = raw[pos]
        pos += 1
        row = bytearray(raw[pos:pos + stride])
        pos += stride
        for index in range(stride):
            left = row[index - channels] if index >= channels else 0
            up = previous[index]
            up_left = previous[index - channels] if index >= channels else 0
            if filter_type == 1:
                row[index] = (row[index] + left) & 0xFF
            elif filter_type == 2:
                row[index] = (row[index] + up) & 0xFF
            elif filter_type == 3:
                row[index] = (row[index] + ((left + up) // 2)) & 0xFF
            elif filter_type == 4:
                row[index] = (row[index] + paeth(left, up, up_left)) & 0xFF
            elif filter_type != 0:
                raise ValueError(f"unsupported filter {filter_type}")
        rows.append(bytes(row))
        previous = row

    return width, height, channels, rows


def saturation(red, green, blue):
    high = max(red, green, blue)
    low = min(red, green, blue)
    if high == 0:
        return 0
    return (high - low) / high


def summarize_png(path):
    width, height, channels, rows = decode_png(path)
    step_x = max(width // 96, 1)
    step_y = max(height // 96, 1)
    sampled = 0
    saturated = 0
    max_saturation = 0
    sum_r = sum_g = sum_b = 0
    bins = {}

    for y in range(0, height, step_y):
        row = rows[y]
        for x in range(0, width, step_x):
            offset = x * channels
            if channels == 1:
                red = green = blue = row[offset]
            else:
                red, green, blue = row[offset], row[offset + 1], row[offset + 2]
            sampled += 1
            sum_r += red
            sum_g += green
            sum_b += blue
            sat = saturation(red, green, blue)
            max_saturation = max(max_saturation, sat)
            luminance = (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255
            if sat > 0.35 and 0.08 < luminance < 0.96:
                saturated += 1
                key = (red // 32 * 32, green // 32 * 32, blue // 32 * 32)
                bins[key] = bins.get(key, 0) + 1

    top_bins = sorted(bins.items(), key=lambda item: item[1], reverse=True)[:8]
    return {
        "file": path,
        "width": width,
        "height": height,
        "sampled_pixels": sampled,
        "average_rgb": [
            round(sum_r / sampled),
            round(sum_g / sampled),
            round(sum_b / sampled)
        ],
        "max_saturation": round(max_saturation, 4),
        "saturated_fraction": round(saturated / sampled, 4),
        "dominant_saturated_bins": [
            {"rgb_bin": list(rgb), "sample_count": count}
            for rgb, count in top_bins
        ],
    }


def main():
    if len(sys.argv) != 2:
        print("usage: analyze-peel-color-smoke.py ATTACHMENTS_DIR", file=sys.stderr)
        return 2

    root = sys.argv[1]
    pngs = []
    for dirpath, _, filenames in os.walk(root):
        for filename in filenames:
            if filename.lower().endswith(".png"):
                pngs.append(os.path.join(dirpath, filename))

    summaries = []
    errors = []
    for path in sorted(pngs):
        try:
            summaries.append(summarize_png(path))
        except Exception as error:
            errors.append({"file": path, "error": str(error)})

    color_rich_images = [
        item for item in summaries
        if item["max_saturation"] >= 0.65 and item["saturated_fraction"] >= 0.01
    ]
    result = {
        "status": "passed" if color_rich_images else "needs-review",
        "image_count": len(summaries),
        "color_rich_image_count": len(color_rich_images),
        "summaries": summaries,
        "errors": errors,
    }
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
