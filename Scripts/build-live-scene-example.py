#!/usr/bin/env python3
"""Build our authored demo into .tmp/live-examples/scene; never reads Workshop assets."""
import json
import pathlib
import struct

root = pathlib.Path(__file__).resolve().parent.parent
source = root / "Examples" / "live-scene"
destination = root / ".tmp" / "live-examples" / "scene"
if destination.resolve() != destination:
    raise SystemExit("Refusing a symlinked example output directory")
destination.mkdir(parents=True, exist_ok=True)
data = (source / "scene.json").read_bytes()
json.loads(data)
def string(value):
    encoded = value.encode()
    return struct.pack("<I", len(encoded)) + encoded
package = string("PKGV0007") + struct.pack("<I", 1) + string("scene.json") + struct.pack("<II", 0, len(data)) + data
for name, content in [("scene.pkg", package), ("project.json", (source / "project.json").read_bytes())]:
    path = destination / name
    if path.is_symlink():
        raise SystemExit("Refusing a symlinked example output file")
    path.write_bytes(content)
print(destination.parent)
