#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns from the broom drawing.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/icon
cp scripts/make-icon.swift build/icon/main.swift
swiftc -O build/icon/main.swift Sources/UI/BroomPath.swift -o build/make-icon
build/make-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
