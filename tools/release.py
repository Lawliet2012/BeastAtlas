#!/usr/bin/env python3
"""
Builds the release archive and, on request, uploads it to CurseForge.

  python -I tools/release.py build                 -> dist/BeastAtlas-<version>.zip (folder BeastAtlas/ inside)
  python -I tools/release.py upload <projectId>    -> builds, then uploads the archive to that CurseForge project

The upload needs the author's API token in the environment variable CF_API_KEY
(https://legacy.curseforge.com/account/api-tokens). The token is never written to disk by this script.
The changelog sent with the file is the top section of CHANGELOG.md.
"""
import json
import os
import re
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NAME = "BeastAtlas"
API = "https://wow.curseforge.com/api"
# what goes into the game's AddOns/BeastAtlas folder
PATTERNS = (("", (".toc", ".lua", ".xml")), ("Data", (".lua",)), ("Media", (".tga",)))
EXTRA = ("README.md", "CHANGELOG.md", "LICENSE", "NOTICE.md")


def toc(field):
    text = open(os.path.join(ROOT, NAME + ".toc"), encoding="utf-8").read()
    m = re.search(rf"^## {re.escape(field)}: *(.+)$", text, re.M)
    return m.group(1).strip() if m else None


def build():
    version = toc("Version")
    out = os.path.join(ROOT, "dist", f"{NAME}-{version}.zip")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    files = []
    for sub, exts in PATTERNS:
        folder = os.path.join(ROOT, sub)
        for f in sorted(os.listdir(folder)):
            if f.endswith(exts) and os.path.isfile(os.path.join(folder, f)):
                files.append(os.path.join(sub, f))
    files += [f for f in EXTRA if os.path.exists(os.path.join(ROOT, f))]
    # every file the TOC loads must be in the archive
    listed = [line.strip().replace("\\", os.sep) for line in
              open(os.path.join(ROOT, NAME + ".toc"), encoding="utf-8").read().splitlines()
              if line.strip() and not line.startswith("#")]
    missing = [f for f in listed if f not in files]
    if missing:
        sys.exit(f"the TOC lists files that are not packed: {missing}")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for f in files:
            z.write(os.path.join(ROOT, f), f"{NAME}/{f.replace(os.sep, '/')}")
    print(f"built {os.path.relpath(out, ROOT)}: {len(files)} files, {os.path.getsize(out) // 1024} KB, version {version}")
    return out, version


def changelog():
    """The newest section of CHANGELOG.md (from the first '## ' heading to the next one)."""
    path = os.path.join(ROOT, "CHANGELOG.md")
    if not os.path.exists(path):
        return ""
    parts = re.split(r"^## ", open(path, encoding="utf-8").read(), flags=re.M)
    return ("## " + parts[1]).strip() if len(parts) > 1 else ""


def curl(*args):
    r = subprocess.run(["curl", "-sS", "-H", "User-Agent: BeastAtlas-release/1.0",
                        "-H", "X-Api-Token: " + os.environ["CF_API_KEY"], *args],
                       capture_output=True, text=True, encoding="utf-8")
    if r.returncode != 0:
        sys.exit("curl failed: " + r.stderr.strip())
    return r.stdout


def upload(project_id):
    if not os.environ.get("CF_API_KEY"):
        sys.exit("set CF_API_KEY to your CurseForge API token first")
    path, version = build()
    interface = toc("Interface")
    versions = [v["id"] for v in json.loads(curl(API + "/game/versions")) if v.get("apiVersion") == interface]
    if not versions:
        sys.exit(f"CurseForge knows no game version with interface {interface}")
    metadata = {
        "changelog": changelog(),
        "changelogType": "markdown",
        "displayName": f"{NAME} {version}",
        "gameVersions": versions,
        "releaseType": "beta" if version.startswith("0.") else "release",
    }
    print(f"uploading {os.path.basename(path)} to project {project_id}: game versions {versions}, {metadata['releaseType']}")
    out = curl("-F", "metadata=" + json.dumps(metadata, ensure_ascii=False), "-F", "file=@" + path,
               f"{API}/projects/{project_id}/upload-file")
    print("CurseForge answered:", out.strip())
    try:
        ok = "id" in json.loads(out)
    except ValueError:
        ok = False
    if not ok:
        sys.exit("upload failed")


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "build":
        build()
    elif len(sys.argv) == 3 and sys.argv[1] == "upload" and sys.argv[2].isdigit():
        upload(sys.argv[2])
    else:
        sys.exit(__doc__)
