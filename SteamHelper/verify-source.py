#!/usr/bin/env python3
"""Verify the pinned archive and that the documented patch recreates vendored C#."""
import hashlib
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

root = Path(__file__).resolve().parent
archive = root / "upstream/DepotDownloader_3.4.0.tar.gz"
expected = "2f09a0aaf003ee01fce44ec9acc0371441172e27d544eb7ccbe7974c01f47f42"
assert hashlib.sha256(archive.read_bytes()).hexdigest() == expected, "Upstream source checksum mismatch"
with tempfile.TemporaryDirectory(prefix="verify-steam-source-", dir=os.environ.get("APP_SCRATCH_DIR")) as scratch:
    scratch = Path(scratch)
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            parts = Path(member.name).parts
            if len(parts) == 3 and parts[1] == "DepotDownloader" and parts[2].endswith(".cs") and member.isfile():
                target = scratch / "DepotDownloader" / parts[2]
                target.parent.mkdir(exist_ok=True)
                target.write_bytes(source.extractfile(member).read())
    with (root / "patches/bridge.patch").open("rb") as patch:
        subprocess.run(["patch", "--batch", "-s", "-p1", "-d", str(scratch)], stdin=patch, check=True)
    for path in (root / "DepotDownloader").glob("*.cs"):
        assert path.read_bytes() == (scratch / "DepotDownloader" / path.name).read_bytes(), f"Patch does not recreate {path.name}"
print("PASS pinned DepotDownloader archive and bridge patch")
