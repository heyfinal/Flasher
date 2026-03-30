#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="${ROOT_DIR}/tools/wimlib/dist"

if command -v wimlib-imagex >/dev/null 2>&1; then
  echo "wimlib-imagex already installed."
  exit 0
fi

if command -v brew >/dev/null 2>&1; then
  echo "Attempting Homebrew install..."
  brew install wimlib
  exit 0
fi

echo "Homebrew not available. Building wimlib from source."
mkdir -p "${ROOT_DIR}/tools"
if [ ! -d "${ROOT_DIR}/tools/wimlib" ]; then
  git clone https://wimlib.net/git/wimlib "${ROOT_DIR}/tools/wimlib"
fi

cd "${ROOT_DIR}/tools/wimlib"
if ! command -v autoreconf >/dev/null 2>&1; then
  echo "Missing autoreconf (autoconf). Install Xcode Command Line Tools, then re-run."
  exit 1
fi

./bootstrap
./configure --prefix="${DEST_DIR}"
make -j4
make install
echo "Installed wimlib to ${DEST_DIR}"
