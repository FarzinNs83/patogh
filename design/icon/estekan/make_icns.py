# Packs PNGs into a macOS .icns (PNG-payload entry types, supported since macOS 10.7).
# usage: python make_icns.py <png-dir> <out.icns>   (png-dir holds mac-<size>.png)
import struct, sys

# entry type -> pixel size; 16/32 use the simplified small cut
TYPES = [("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64), ("ic07", 128),
         ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024)]

src, out = sys.argv[1], sys.argv[2]
body = b""
for t, n in TYPES:
    png = open(f"{src}/mac-{n}.png", "rb").read()
    assert png[:8] == b"\x89PNG\r\n\x1a\n", f"mac-{n}.png is not a PNG"
    assert struct.unpack(">II", png[16:24]) == (n, n), f"mac-{n}.png is not {n}x{n}"
    body += t.encode() + struct.pack(">I", len(png) + 8) + png
open(out, "wb").write(b"icns" + struct.pack(">I", len(body) + 8) + body)
print("wrote", out, len(body) + 8, "bytes")
