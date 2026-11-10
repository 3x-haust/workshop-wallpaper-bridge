#!/usr/bin/env python3
"""Package this separate GPL component's source, build inputs, and dependency notices."""
import gzip
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
destination = Path(sys.argv[1])
paths = [p for p in (root / "SteamHelper").rglob("*") if p.is_file() and not {"bin", "obj", "__pycache__"}.intersection(p.relative_to(root / "SteamHelper").parts)]
paths += [root / "Scripts/build-steam-helper.sh", root / "Scripts/steam-helper.env"]
with (destination / "steam-helper-source.tar.gz").open("wb") as output:
    with gzip.GzipFile(fileobj=output, mode="wb", mtime=0, filename="") as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as archive:
            for path in sorted(paths):
                data = path.read_bytes()
                info = tarfile.TarInfo(str(path.relative_to(root)))
                info.size = len(data)
                info.mode = 0o644
                archive.addfile(info, io.BytesIO(data))

packages = Path(os.environ["NUGET_PACKAGES"])
lock = json.loads((root / "SteamHelper/packages.lock.json").read_text())
manifest = []
for name, entry in lock["dependencies"]["net9.0"].items():
    version = entry["resolved"]
    package = packages / name.lower() / version
    notices = destination / "Licenses" / f"{name}-{version}"
    notices.mkdir(parents=True, exist_ok=True)
    spec = next(package.glob("*.nuspec"))
    metadata = ET.parse(spec).getroot().find("{*}metadata")
    license_info = metadata.find("{*}license")
    repository = metadata.find("{*}repository")
    manifest.append({"name": name, "version": version, "license": license_info.text if license_info is not None else None, "source": repository.attrib if repository is not None else None, "nuget": f"https://www.nuget.org/packages/{name}/{version}"})
    for path in package.rglob("*"):
        if path.is_file() and (path.suffix == ".nuspec" or any(word in path.name.lower() for word in ["license", "notice", "copying", "3rd party"])):
            (notices / path.name).write_bytes(path.read_bytes())
(destination / "Licenses/dependencies.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("Packaged helper source, upstream archive, patch, lockfile, and dependency notices")
