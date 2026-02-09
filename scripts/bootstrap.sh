#!/usr/bin/env bash
set -euo pipefail

echo "==> Swift toolchain:"
swift --version

echo "==> Building..."
swift build

echo "==> Testing..."
swift test

echo "Done."
