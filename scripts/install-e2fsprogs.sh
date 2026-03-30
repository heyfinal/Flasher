#!/usr/bin/env bash
set -euo pipefail

if command -v mkfs.ext4 >/dev/null 2>&1; then
  echo "mkfs.ext4 already installed."
  exit 0
fi

if command -v brew >/dev/null 2>&1; then
  echo "Installing e2fsprogs via Homebrew..."
  brew install e2fsprogs
  exit 0
fi

echo "Homebrew not available. Install e2fsprogs to get mkfs.ext4."
exit 1
