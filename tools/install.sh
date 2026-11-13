#!/usr/bin/env bash
# Copies the addon (without tools/ and docs/) into the game's AddOns folder.
# Usage: bash tools/install.sh ["/path/to/Interface/AddOns"]
set -e
SRC="$(cd "$(dirname "$0")/.." && pwd)"
DST="${1:-/c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns}/BeastAtlas"
mkdir -p "$DST/Data" "$DST/Media"
cp "$SRC"/BeastAtlas.toc "$SRC"/*.lua "$SRC"/*.xml "$DST/"
cp "$SRC"/Data/*.lua "$DST/Data/"
cp "$SRC"/Media/*.tga "$DST/Media/"
echo "installed to $DST"
