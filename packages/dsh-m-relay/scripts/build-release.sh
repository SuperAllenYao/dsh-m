#!/usr/bin/env bash
# build-release.sh — cross-compile the relay for the Linux targets the one-click
# deploy engine can push, and stage the artifacts inside the dsh-m-link plugin.
#
# The deploy engine ships the binaries as plugin assets (no network download at
# deploy time): packages/dsh-m-link/assets/relay/<target>/dshm-relay plus an
# sha256 manifest (assets/relay/index.json) that the engine verifies on both the
# Mac and the server before installing.
#
# Usage:
#   bash packages/dsh-m-relay/scripts/build-release.sh            # amd64 + arm64
#   bash packages/dsh-m-relay/scripts/build-release.sh linux-arm64
#
# Reproducibility notes:
#   - CGO disabled -> fully static binary, runs on any Linux with a modern kernel.
#   - -trimpath strips build paths; -s -w strips symbols (smaller upload).
#   - The relay reports a single version constant (internal/relay.Version); this
#     script records it in the manifest so the engine can tell "same version"
#     from "newer/older binary" but always compares sha256 for the actual upload.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
RELAY_DIR="$REPO_ROOT/packages/dsh-m-relay"
ASSET_DIR="$REPO_ROOT/packages/dsh-m-link/assets/relay"

targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then
  targets=(linux-amd64 linux-arm64)
fi

command -v go >/dev/null 2>&1 || { echo "build-release: go not found in PATH" >&2; exit 1; }

version="$(cd "$RELAY_DIR" && go run ./... version 2>/dev/null | sed -n 's/^dshm-relay \([^ ]*\).*/\1/p' | head -1)" || true
if [[ -z "${version:-}" ]]; then
  version="$(grep -oE 'Version = "[^"]+"' "$RELAY_DIR/internal/relay/relay.go" | head -1 | sed -E 's/.*"([^"]+)"/\1/')"
fi
echo "build-release: relay version ${version}"

mkdir -p "$ASSET_DIR"
entries=()
for target in "${targets[@]}"; do
  case "$target" in
    linux-amd64) goarch=amd64 ;;
    linux-arm64) goarch=arm64 ;;
    *) echo "build-release: unsupported target '$target' (expected linux-amd64|linux-arm64)" >&2; exit 2 ;;
  esac
  out_dir="$ASSET_DIR/$target"
  out="$out_dir/dshm-relay"
  mkdir -p "$out_dir"
  echo "build-release: building $target"
  ( cd "$RELAY_DIR" && CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" \
      go build -trimpath -ldflags "-s -w" -o "$out" . )
  chmod 0755 "$out"
  sha="$(shasum -a 256 "$out" | awk '{print $1}')"
  size="$(stat -f '%z' "$out" 2>/dev/null || stat -c '%s' "$out")"
  entries+=("$target|$sha|$size")
  echo "  $target  sha256=$sha  size=$size"
done

# Merge the manifest with existing entries so building one target does not drop
# the other. Sort keys for a stable file.
node - "$ASSET_DIR/index.json" "$version" "${entries[@]}" <<'NODE'
const { readFileSync, writeFileSync } = require('node:fs');
const [file, version, ...entries] = process.argv.slice(2);
let manifest = { version, generatedAt: new Date().toISOString(), binaries: {} };
try {
  const previous = JSON.parse(readFileSync(file, 'utf8'));
  if (previous && typeof previous === 'object' && previous.binaries) manifest.binaries = previous.binaries;
} catch {
  /* first run */
}
manifest.version = version;
manifest.generatedAt = new Date().toISOString();
for (const entry of entries) {
  const [target, sha256, size] = entry.split('|');
  manifest.binaries[target] = { file: target + '/dshm-relay', sha256, size: Number(size) };
}
// Deterministic key order.
const sorted = {};
for (const key of Object.keys(manifest.binaries).sort()) sorted[key] = manifest.binaries[key];
manifest.binaries = sorted;
writeFileSync(file, JSON.stringify(manifest, null, 2) + '\n');
NODE

# Stage the server-side installer + systemd unit next to the binaries so the
# dsh-m-link plugin is self-contained at deploy time.
mkdir -p "$ASSET_DIR/deploy"
cp "$RELAY_DIR/deploy/install.sh" "$ASSET_DIR/deploy/install.sh"
cp "$RELAY_DIR/deploy/dshm-relay.service" "$ASSET_DIR/deploy/dshm-relay.service"
chmod 0755 "$ASSET_DIR/deploy/install.sh"
echo "build-release: staged deploy/install.sh + deploy/dshm-relay.service"

echo "build-release: manifest -> $ASSET_DIR/index.json"
