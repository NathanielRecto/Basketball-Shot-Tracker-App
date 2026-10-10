#!/usr/bin/env bash
# Copy the Core ML detector exported by ../Python_Raw/scripts/export_coreml.py into Resources/ (gitignored).
#
#   scripts/sync_model.sh                      # DetectorV2 from ../Python_Raw/exports/coreml
#   scripts/sync_model.sh path/to/coreml DetectorV2
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
src="${1:-$here/../Python_Raw/exports/coreml}"
name="${2:-DetectorV2}"

for f in "$src/$name.mlpackage" "$src/$name.json"; do
  [ -e "$f" ] || { echo "missing $f: run Python_Raw/scripts/export_coreml.py first" >&2; exit 1; }
done
mkdir -p "$here/Resources"
rm -rf "$here/Resources/$name.mlpackage"
cp -R "$src/$name.mlpackage" "$here/Resources/"
cp "$src/$name.json" "$here/Resources/"
echo "copied $name from $src"
grep -E '"(weights_sha256|precision)"' "$here/Resources/$name.json"
