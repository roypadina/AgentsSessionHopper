#!/usr/bin/env python3
"""Keep only IHDR/IDAT/IEND in PNGs (drops eXIf, sRGB/ICC, text chunks) before they go public.
Usage: Scripts/strip_png_metadata.py docs/screenshots/*.png"""
import struct, sys, zlib

for path in sys.argv[1:]:
    data = open(path, "rb").read()
    out, i = [data[:8]], 8
    while i < len(data):
        n, kind = struct.unpack(">I4s", data[i:i + 8])
        if kind in (b"IHDR", b"IDAT", b"IEND"):
            out.append(data[i:i + 12 + n])
        i += 12 + n
    open(path, "wb").write(b"".join(out))
