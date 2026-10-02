#!/bin/bash
# Downloads the embedded Python runtime and yt-dlp into the project.
# Run before `xcodegen generate` (the GitHub workflow does this for you).
set -euo pipefail
cd "$(dirname "$0")/.."

PY_VERSION="3.13"
PY_BUILD="b15"
PY_URL="https://github.com/beeware/Python-Apple-support/releases/download/${PY_VERSION}-${PY_BUILD}/Python-${PY_VERSION}-iOS-support.${PY_BUILD}.tar.gz"
PIP="${PYTHON:-python3} -m pip"

if [ ! -d Python.xcframework ]; then
  echo "Downloading Python ${PY_VERSION} for iOS (${PY_BUILD})…"
  TMP=$(mktemp -d)
  curl -fsSL "$PY_URL" -o "$TMP/python.tar.gz"
  tar -xzf "$TMP/python.tar.gz" -C "$TMP"
  mv "$TMP/Python.xcframework" .
  rm -rf "$TMP"
fi

echo "Installing yt-dlp (pure Python, no ffmpeg)…"
rm -rf Python/app_packages
$PIP install --no-deps --no-compile --target Python/app_packages yt-dlp certifi

# The JavaScript challenge solver must match the version yt-dlp expects
EJS_VERSION=$(sed -n "s/^VERSION = '\(.*\)'/\1/p" Python/app_packages/yt_dlp/extractor/youtube/jsc/_builtin/vendor/_info.py)
echo "Installing yt-dlp-ejs ${EJS_VERSION}…"
$PIP install --no-deps --no-compile --target Python/app_packages "yt-dlp-ejs==${EJS_VERSION}"

# Command-line launchers and caches aren't needed inside the app
rm -rf Python/app_packages/bin Python/app_packages/share
find Python/app_packages -name "__pycache__" -type d -prune -exec rm -rf {} +
echo "Done: $(ls Python/app_packages | tr '\n' ' ')"
