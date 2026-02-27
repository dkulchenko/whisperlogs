#!/usr/bin/env bash
# Downloads SQLean regexp extension binaries for all supported platforms.
# Run once locally, then commit the binaries to priv/sqlite_extensions/.
#
# Requires: curl, unzip
#
# Usage: bin/download_sqlean.sh

set -euo pipefail

VERSION="0.28.1"
BASE_URL="https://github.com/nalgeon/sqlean/releases/download/${VERSION}"
DEST_DIR="priv/sqlite_extensions"

declare -A PLATFORM_MAP=(
  ["linux-x64"]="linux-x64/regexp.so"
  ["linux-arm64"]="linux-arm64/regexp.so"
  ["macos-x64"]="macos-x64/regexp.dylib"
  ["macos-arm64"]="macos-arm64/regexp.dylib"
  ["win-x64"]="win-x64/regexp.dll"
)

declare -A ZIP_MAP=(
  ["linux-x64"]="sqlean-linux-x64.zip"
  ["linux-arm64"]="sqlean-linux-arm64.zip"
  ["macos-x64"]="sqlean-macos-x64.zip"
  ["macos-arm64"]="sqlean-macos-arm64.zip"
  ["win-x64"]="sqlean-win-x64.zip"
)

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

for platform in "${!PLATFORM_MAP[@]}"; do
  zip_name="${ZIP_MAP[$platform]}"
  dest_path="${DEST_DIR}/${PLATFORM_MAP[$platform]}"
  dest_dir=$(dirname "$dest_path")

  echo "Downloading ${zip_name}..."
  curl -sL "${BASE_URL}/${zip_name}" -o "${TMP_DIR}/${zip_name}"

  mkdir -p "$dest_dir"

  # Extract only the regexp extension file
  ext_file=$(basename "$dest_path")
  unzip -o -j "${TMP_DIR}/${zip_name}" "$ext_file" -d "$dest_dir"

  if [ -f "$dest_path" ]; then
    echo "  -> ${dest_path} ($(du -h "$dest_path" | cut -f1))"
  else
    echo "  WARNING: Failed to extract ${dest_path}"
  fi
done

echo ""
echo "Done! Total size:"
du -sh "$DEST_DIR"
