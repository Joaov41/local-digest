#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="$ROOT_DIR/apple_foundation_bridge"
OUT_DIR="$ROOT_DIR/bin"
OUT_BIN="$OUT_DIR/apple_foundation_bridge"

mkdir -p "$OUT_DIR"

swiftc -O -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -target arm64-apple-macos26.0 \
    -parse-as-library \
    "$SRC_DIR/AppleFoundationBridge.swift" \
    -o "$OUT_BIN"

echo "Built $OUT_BIN"
