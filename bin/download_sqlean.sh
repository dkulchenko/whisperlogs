#!/usr/bin/env bash
set -euo pipefail

VERSION="${SQLEAN_VERSION:-0.28.1}"
BASE_URL="${SQLEAN_BASE_URL:-https://github.com/nalgeon/sqlean/releases/download/${VERSION}}"
DEST_DIR="${SQLEAN_DEST_DIR:-priv/sqlite_extensions}"
MANIFEST="${SQLEAN_MANIFEST:-${DEST_DIR}/manifest.tsv}"

expected_platforms=(linux-x64 linux-arm64 macos-x64 macos-arm64 win-x64)
declare -A expected_archives=(
  [linux-x64]="sqlean-linux-x64.zip"
  [linux-arm64]="sqlean-linux-arm64.zip"
  [macos-x64]="sqlean-macos-x64.zip"
  [macos-arm64]="sqlean-macos-arm64.zip"
  [win-x64]="sqlean-win-x64.zip"
)
declare -A expected_libraries=(
  [linux-x64]="regexp.so"
  [linux-arm64]="regexp.so"
  [macos-x64]="regexp.dylib"
  [macos-arm64]="regexp.dylib"
  [win-x64]="regexp.dll"
)
declare -A seen=()

while read -r platform archive archive_hash library library_hash extra || [[ -n "${platform:-}" ]]; do
  [[ -z "${platform:-}" || "$platform" == \#* ]] && continue
  [[ -z "${extra:-}" ]] || { echo "malformed SQLean manifest row for ${platform}" >&2; exit 1; }
  [[ -n "${expected_archives[$platform]+present}" ]] || { echo "unexpected SQLean platform ${platform}" >&2; exit 1; }
  [[ -z "${seen[$platform]+present}" ]] || { echo "duplicate SQLean platform ${platform}" >&2; exit 1; }
  [[ "$archive" == "${expected_archives[$platform]}" ]] || { echo "unexpected archive for ${platform}" >&2; exit 1; }
  [[ "$library" == "${expected_libraries[$platform]}" ]] || { echo "unexpected library for ${platform}" >&2; exit 1; }
  [[ "$archive_hash" =~ ^[0-9a-f]{64}$ ]] || { echo "invalid archive hash for ${platform}" >&2; exit 1; }
  [[ "$library_hash" =~ ^[0-9a-f]{64}$ ]] || { echo "invalid library hash for ${platform}" >&2; exit 1; }
  seen[$platform]=1
done < "$MANIFEST"

for platform in "${expected_platforms[@]}"; do
  [[ -n "${seen[$platform]+present}" ]] || { echo "missing SQLean platform ${platform}" >&2; exit 1; }
done

TMP_DIR=$(mktemp -d)
STAGE_DIR="${TMP_DIR}/staged"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$STAGE_DIR"
cp "$MANIFEST" "${STAGE_DIR}/manifest.tsv"

while read -r platform archive archive_hash library library_hash || [[ -n "${platform:-}" ]]; do
  [[ -z "${platform:-}" || "$platform" == \#* ]] && continue
  archive_path="${TMP_DIR}/${archive}"
  platform_dir="${STAGE_DIR}/${platform}"
  staged_library="${platform_dir}/${library}"

  curl --fail --silent --show-error --location "${BASE_URL}/${archive}" --output "$archive_path"
  printf '%s  %s\n' "$archive_hash" "$archive_path" | sha256sum --check --status

  entries=$(unzip -Z1 "$archive_path")
  matches=$(printf '%s\n' "$entries" | awk -v wanted="$library" '$0 == wanted {count++} END {print count+0}')
  [[ "$matches" == "1" ]] || { echo "archive ${archive} does not contain exactly one ${library}" >&2; exit 1; }

  mkdir -p "$platform_dir"
  unzip -p "$archive_path" "$library" > "$staged_library"
  [[ -f "$staged_library" && ! -L "$staged_library" ]] || { echo "staged library is not regular" >&2; exit 1; }
  printf '%s  %s\n' "$library_hash" "$staged_library" | sha256sum --check --status
done < "$MANIFEST"

backup="${TMP_DIR}/previous"
if [[ -e "$DEST_DIR" ]]; then mv "$DEST_DIR" "$backup"; fi
if ! mv "$STAGE_DIR" "$DEST_DIR"; then
  [[ -e "$backup" ]] && mv "$backup" "$DEST_DIR"
  exit 1
fi

echo "Verified SQLean ${VERSION} libraries installed in ${DEST_DIR}"
