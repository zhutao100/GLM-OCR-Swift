#!/usr/bin/env bash
set -euo pipefail

echo "==> Swift toolchain:"
swift --version

echo "==> Building & Testing..."
scripts/verify_fast.sh

echo "Done."
