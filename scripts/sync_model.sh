#!/usr/bin/env bash
# Copy the Core ML detector exported by ../Python_Raw/scripts/export_coreml.py into Resources/ (gitignored),
# plus, when ../Python_Raw/exports/parity exists (scripts/export_parity_frames.py), the parity-check frames,
# their PyTorch reference and the fp32 model into Resources/Parity. Resources/Parity always exists (xtool.yml
# bundles it); without frames the app hides its Check button.
#
#   scripts/sync_model.sh                                  # from ../Python_Raw/exports
#   scripts/sync_model.sh --no-parity                      # a build for someone else: no dev frames (they show people)
#   scripts/sync_model.sh path/to/exports DetectorV2
set -euo pipefail
no_parity=0
if [ "${1:-}" = "--no-parity" ]; then no_parity=1; shift; fi
here="$(cd "$(dirname "$0")/.." && pwd)"
exports="${1:-$here/../Python_Raw/exports}"
name="${2:-DetectorV2}"
coreml="$exports/coreml"
parity="$exports/parity"

for f in "$coreml/$name.mlpackage" "$coreml/$name.json"; do
  [ -e "$f" ] || { echo "missing $f: run Python_Raw/scripts/export_coreml.py first" >&2; exit 1; }
done
mkdir -p "$here/Resources"
rm -rf "$here/Resources/$name.mlpackage" "$here/Resources/Parity"
cp -R "$coreml/$name.mlpackage" "$here/Resources/"
cp "$coreml/$name.json" "$here/Resources/"
echo "copied $name from $coreml"
grep -E '"(weights_sha256|precision)"' "$here/Resources/$name.json"

mkdir -p "$here/Resources/Parity"
if [ "$no_parity" = 1 ]; then
  echo "no parity check in this build (--no-parity): the app's Check button stays hidden"
elif [ -f "$parity/reference.json" ]; then
  cp -R "$parity/frames" "$parity/reference.json" "$here/Resources/Parity/"
  if [ -e "$coreml/${name}_fp32.mlpackage" ]; then
    cp -R "$coreml/${name}_fp32.mlpackage" "$coreml/${name}_fp32.json" "$here/Resources/Parity/"
  fi
  echo "copied parity check: $(ls "$here/Resources/Parity/frames" | wc -l) frames$( [ -e "$here/Resources/Parity/${name}_fp32.mlpackage" ] && echo ' + fp32 model')"
else
  echo "no parity frames ($parity/reference.json): the app's Check button stays hidden"
fi
