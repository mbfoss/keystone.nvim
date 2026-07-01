#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/mbfoss/neotoolkit.nvim"
DEST="lua/keystone/util"
TMP=$(mktemp -d)

cd "$(dirname "$0")/.."

echo "Cloning $REPO..."
git clone --depth=1 "$REPO" "$TMP/neotoolkit"

echo "Syncing files into $DEST..."
rm -f "$DEST"/*.lua
cp "$TMP/neotoolkit/lua/neotoolkit/"*.lua "$DEST/"

echo "Rewriting require paths..."
sed -i '' 's/require(\(['"'"'"]\)neotoolkit\./require(\1keystone.util./g' "$DEST"/*.lua
sed -i '' 's/require \(['"'"'"]\)neotoolkit\./require \1keystone.util./g' "$DEST"/*.lua

echo "Rewriting type annotations..."
sed -i '' 's/neotoolkit\./keystone.util./g' "$DEST"/*.lua

echo "Removing vendored unit test files..."
rm -f tests/regex_spec.lua tests/tree_spec.lua

rm -rf "$TMP"

echo "Done."
