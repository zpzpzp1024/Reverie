#!/usr/bin/env python3
"""Build a flat APT repository (the kind Sileo and Zebra consume) from .deb files.

Usage: make_repo.py <deb-dir> <out-dir>

The output directory contains the packages, a `Packages` index (+ gzip copy) and
a `Release` file. Serve it over HTTPS - GitHub Pages is enough - and add the URL
in Sileo as a source.
"""

from __future__ import annotations

import bz2
import glob
import gzip
import hashlib
import io
import lzma
import os
import shutil
import sys
import tarfile


def ar_members(path: str):
    """Yield (name, payload) for every member of an ar archive."""
    with open(path, "rb") as handle:
        if handle.read(8) != b"!<arch>\n":
            raise SystemExit(f"{path}: not a deb (bad ar magic)")

        while True:
            header = handle.read(60)
            if len(header) < 60:
                return

            name = header[:16].decode("ascii", "replace").strip().rstrip("/")
            size = int(header[48:58].decode("ascii", "replace").strip() or 0)
            payload = handle.read(size)

            if size % 2:
                handle.read(1)

            yield name, payload


def control_text(path: str) -> str:
    """Return the control file stored inside a deb."""
    for name, payload in ar_members(path):
        if not name.startswith("control.tar"):
            continue

        if name.endswith(".gz"):
            payload = gzip.decompress(payload)
        elif name.endswith(".xz"):
            payload = lzma.decompress(payload)
        elif name.endswith(".bz2"):
            payload = bz2.decompress(payload)

        with tarfile.open(fileobj=io.BytesIO(payload)) as archive:
            for member in archive.getmembers():
                if member.name.lstrip("./") == "control":
                    return archive.extractfile(member).read().decode("utf-8")

    raise SystemExit(f"{path}: no control file")


def stanza(path: str) -> str:
    """Control fields for a package, with the index-only fields filled in."""
    rewritten = {"filename", "size", "sha256", "md5sum"}
    lines = [line.rstrip() for line in control_text(path).strip().splitlines()]
    kept = []

    for line in lines:
        if line and not line[0].isspace() and ":" in line:
            field = line.split(":", 1)[0].strip().lower()
            if field in rewritten:
                continue

        kept.append(line)

    with open(path, "rb") as handle:
        payload = handle.read()

    kept += [
        f"Filename: ./{os.path.basename(path)}",
        f"Size: {len(payload)}",
        f"SHA256: {hashlib.sha256(payload).hexdigest()}",
        f"MD5sum: {hashlib.md5(payload).hexdigest()}",
    ]

    return "\n".join(kept)


def release_file(packages: list[str]) -> str:
    return (
        "Origin: Reverie\n"
        "Label: Reverie\n"
        "Suite: stable\n"
        "Version: 1.0\n"
        "Codename: ios\n"
        "Architectures: iphoneos-arm64\n"
        "Components: main\n"
        f"Description: Reverie - hibernation for car-mounted iPhones ({len(packages)} package(s))\n"
    )


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)

    source, target = sys.argv[1], sys.argv[2]
    debs = sorted(glob.glob(os.path.join(source, "*.deb")))

    if not debs:
        raise SystemExit(f"{source}: no .deb files")

    os.makedirs(target, exist_ok=True)
    stanzas = []

    for deb in debs:
        shutil.copy2(deb, os.path.join(target, os.path.basename(deb)))
        stanzas.append(stanza(deb))
        print(f"indexed {os.path.basename(deb)}")

    index = "\n\n".join(stanzas) + "\n"

    with open(os.path.join(target, "Packages"), "w", encoding="utf-8", newline="\n") as handle:
        handle.write(index)

    with gzip.open(os.path.join(target, "Packages.gz"), "wb") as handle:
        handle.write(index.encode("utf-8"))

    with open(os.path.join(target, "Release"), "w", encoding="utf-8", newline="\n") as handle:
        handle.write(release_file(debs))

    icon = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Prefs", "Resources", "icon@2x.png")

    if os.path.exists(icon):
        shutil.copy2(icon, os.path.join(target, "CydiaIcon.png"))

    print(f"wrote {len(debs)} package(s) to {target}")


if __name__ == "__main__":
    main()
