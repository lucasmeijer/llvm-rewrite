#!/usr/bin/env bash
# Makes sure the Jai compiler is installed at /persistent/toolchains/jai and prints the path of its binary.
#
# The download URL is private. It's provided to workspaces as the JAI_COMPILER_URL environment variable and must
# never be written into this repository, logs, or reports. /persistent is shared by all workspaces from this template,
# so this downloads (~450 MB) and unpacks (~1.3 GB) only once. To upgrade, delete /persistent/toolchains/jai and
# change the URL.
set -euo pipefail

root=/persistent/toolchains
jai="$root/jai/bin/jai-linux"

if [ ! -x "$jai" ]; then
  if [ -z "${JAI_COMPILER_URL:-}" ]; then
    echo "ensure-jai: Jai isn't installed and JAI_COMPILER_URL is not set; ask the human for it" >&2
    exit 1
  fi
  mkdir -p "$root"
  # Serialize concurrent installs from parallel agents.
  exec 9>"$root/.jai-install.lock"
  flock 9
  if [ ! -x "$jai" ]; then
    tmp="$(mktemp -d "$root/.jai-download.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT
    echo "ensure-jai: downloading the Jai compiler (once per template)..." >&2
    curl -fsSL -o "$tmp/jai.zip" "$JAI_COMPILER_URL"
    unzip -q "$tmp/jai.zip" -d "$tmp/unpacked"
    chmod +x "$tmp/unpacked/jai/bin/"*-linux
    rm -rf "$root/jai"
    mv "$tmp/unpacked/jai" "$root/jai"
  fi
fi
echo "$jai"
