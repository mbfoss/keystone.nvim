#!/usr/bin/env bash
set -euo pipefail

REPO="https://github.com/mbfoss/neotoolkit.nvim"
DEST="lua/keystone/util"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cd "$(dirname "$0")/.."

if [[ -n "${LOCAL:-}" ]]; then
    echo "Using local repo: $LOCAL"
    cp -r "$LOCAL" "$TMP/neotoolkit"
else
    echo "Cloning $REPO..."
    git clone --depth=1 "$REPO" "$TMP/neotoolkit"
fi

echo "Syncing files into $DEST..."
mkdir -p "$DEST"
rm -f "$DEST"/*.lua
cp "$TMP/neotoolkit/lua/neotoolkit/"*.lua "$DEST/"

echo "Rewriting require paths..."
sed -i '' 's/require(\(['"'"'"]\)neotoolkit\./require(\1keystone.util./g' "$DEST"/*.lua
sed -i '' 's/require \(['"'"'"]\)neotoolkit\./require \1keystone.util./g' "$DEST"/*.lua

echo "Rewriting type annotations..."
sed -i '' 's/neotoolkit\./keystone.util./g' "$DEST"/*.lua

echo "Removing vendored unit test files..."
rm -f tests/regex_spec.lua tests/tree_spec.lua

echo "Done."
