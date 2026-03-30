#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${1:-}"
if [ -z "$APP_PATH" ]; then
  echo "Usage: $(basename "$0") /path/to/Flasher.app"
  exit 1
fi

BIN_PATH="${APP_PATH}/Contents/MacOS/Flasher"
if [ ! -x "$BIN_PATH" ]; then
  echo "Executable not found at ${BIN_PATH}"
  exit 1
fi

sudo "$BIN_PATH"
