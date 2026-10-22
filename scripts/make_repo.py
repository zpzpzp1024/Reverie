#!/usr/bin/env python3
"""Build a flat APT repository (the kind Sileo and Zebra consume) from .deb files.

Usage: make_repo.py <deb-dir> <out-dir> [base-url]

The output directory contains the packages, a `Packages` index (+ gzip copy), a
`Release` file and a small landing page. Serve it over HTTPS - GitHub Pages is
enough - and add the URL in Sileo as a source.
"""

from __future__ import annotations

import bz2
import glob
import gzip
import hashlib
import html
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


def fields(text: str) -> dict[str, str]:
    """First value of each control field, keyed by lowercased name."""
    parsed: dict[str, str] = {}

    for line in text.splitlines():
        if not line or line[0].isspace() or ":" not in line:
            continue

        key, value = line.split(":", 1)
        parsed.setdefault(key.strip().lower(), value.strip())

    return parsed


def stanza(path: str) -> tuple[str, dict[str, str]]:
    """Control fields for a package, with the index-only fields filled in."""
    rewritten = {"filename", "size", "sha256", "md5sum"}
    text = control_text(path)
    lines = [line.rstrip() for line in text.strip().splitlines()]
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

    parsed = fields(text)
    parsed["filename"] = os.path.basename(path)
    parsed["size"] = str(len(payload))
    parsed["sha256"] = hashlib.sha256(payload).hexdigest()

    return "\n".join(kept), parsed


def release_file(count: int) -> str:
    return (
        "Origin: Reverie\n"
        "Label: Reverie\n"
        "Suite: stable\n"
        "Version: 1.0\n"
        "Codename: ios\n"
        "Architectures: iphoneos-arm64\n"
        "Components: main\n"
        f"Description: Reverie - hibernation for car-mounted iPhones ({count} package(s))\n"
    )


def landing_page(packages: list[dict[str, str]], base_url: str) -> str:
    cards = []

    for package in packages:
        name = html.escape(package.get("name") or package.get("package", ""))
        version = html.escape(package.get("version", ""))
        description = html.escape(package.get("description", ""))
        filename = html.escape(package.get("filename", ""))
        size = int(package.get("size", "0")) / 1024

        cards.append(
            f'<li>\n'
            f'  <div>\n'
            f'    <strong>{name}</strong><span class="version">{version}</span>\n'
            f'    <p>{description} &middot; {size:.0f} KB</p>\n'
            f'  </div>\n'
            f'  <a class="button" href="./{filename}">Download</a>\n'
            f'</li>'
        )

    source = html.escape(base_url) if base_url else "the URL of this page"

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Reverie</title>
<style>
  :root {{
    color-scheme: dark;
    --bg: #0b0d10;
    --card: #14181d;
    --line: #232a33;
    --text: #e8eaed;
    --muted: #9aa4b2;
    --accent: #7aa2ff;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0;
    background: var(--bg);
    color: var(--text);
    font: 16px/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    -webkit-text-size-adjust: 100%;
  }}
  main {{ max-width: 640px; margin: 0 auto; padding: 48px 20px 64px; }}
  header {{ display: flex; gap: 16px; align-items: center; margin-bottom: 36px; }}
  header img {{ width: 64px; height: 64px; border-radius: 14px; }}
  h1 {{ margin: 0; font-size: 1.5rem; letter-spacing: -0.02em; }}
  .sub {{ margin: 2px 0 0; color: var(--muted); font-size: 0.9rem; }}
  h2 {{
    font-size: 0.75rem;
    text-transform: uppercase;
    letter-spacing: 0.09em;
    color: var(--muted);
    margin: 34px 0 10px;
  }}
  .url {{
    display: block;
    padding: 12px 14px;
    border-radius: 10px;
    background: var(--card);
    border: 1px solid var(--line);
    font: 14px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace;
    word-break: break-all;
    user-select: all;
  }}
  ul {{ list-style: none; padding: 0; margin: 0; display: grid; gap: 12px; }}
  ul li {{
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 16px;
    padding: 16px;
    background: var(--card);
    border: 1px solid var(--line);
    border-radius: 14px;
  }}
  ul li p {{ margin: 4px 0 0; color: var(--muted); font-size: 0.85rem; }}
  .version {{ color: var(--muted); font-size: 0.85rem; margin-left: 8px; }}
  .button {{
    flex: none;
    padding: 9px 15px;
    border-radius: 999px;
    background: var(--accent);
    color: #08101f;
    text-decoration: none;
    font-weight: 600;
    font-size: 0.85rem;
  }}
  ol {{ color: var(--muted); font-size: 0.9rem; padding-left: 20px; margin: 0; }}
  ol li {{ padding: 2px 0; }}
  footer {{ margin-top: 44px; color: #5f6b7a; font-size: 0.78rem; }}
</style>
</head>
<body>
<main>
  <header>
    <img src="CydiaIcon.png" alt="" />
    <div>
      <h1>Reverie</h1>
      <p class="sub">Hibernation for car-mounted iPhones</p>
    </div>
  </header>

  <h2>Add as a Sileo source</h2>
  <code class="url">{source}</code>
  <ol>
    <li>Open Sileo &rarr; Sources &rarr; +</li>
    <li>Paste the URL above and add it</li>
    <li>Search for Reverie, install, then respring</li>
  </ol>

  <h2>Packages</h2>
  <ul>
{chr(10).join(cards)}
  </ul>

  <footer>Requires iOS 13 or later, a rootless jailbreak, PreferenceLoader and CCSupport.</footer>
</main>
</body>
</html>
"""


def main() -> None:
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)

    source, target = sys.argv[1], sys.argv[2]
    base_url = sys.argv[3] if len(sys.argv) == 4 else ""
    debs = sorted(glob.glob(os.path.join(source, "*.deb")))

    if not debs:
        raise SystemExit(f"{source}: no .deb files")

    os.makedirs(target, exist_ok=True)
    stanzas = []
    packages = []

    for deb in debs:
        shutil.copy2(deb, os.path.join(target, os.path.basename(deb)))
        text, package = stanza(deb)
        stanzas.append(text)
        packages.append(package)
        print(f"indexed {os.path.basename(deb)}")

    index = "\n\n".join(stanzas) + "\n"

    with open(os.path.join(target, "Packages"), "w", encoding="utf-8", newline="\n") as handle:
        handle.write(index)

    with gzip.open(os.path.join(target, "Packages.gz"), "wb") as handle:
        handle.write(index.encode("utf-8"))

    with open(os.path.join(target, "Release"), "w", encoding="utf-8", newline="\n") as handle:
        handle.write(release_file(len(debs)))

    with open(os.path.join(target, "index.html"), "w", encoding="utf-8", newline="\n") as handle:
        handle.write(landing_page(packages, base_url))

    icon = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Prefs", "Resources", "icon@2x.png")

    if os.path.exists(icon):
        shutil.copy2(icon, os.path.join(target, "CydiaIcon.png"))

    print(f"wrote {len(debs)} package(s) to {target}")


if __name__ == "__main__":
    main()
