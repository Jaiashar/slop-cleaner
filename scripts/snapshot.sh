#!/usr/bin/env bash
# Asks the running Slop Cleaner to render its popover to a PNG.
#   scripts/snapshot.sh [out.png] [now|automate|demo|demo-automate] [search text to expand]
# "demo" modes render made-up data (for screenshots you can share).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(pwd)/${1:-build/popover.png}"
rm -f "$OUT"
swift -e "import Foundation; DistributedNotificationCenter.default().postNotificationName(.init(\"slopcleaner.debug.snapshot\"), object: \"$OUT|${2:-now}|${3:-}\", userInfo: nil, deliverImmediately: true)"
for _ in $(seq 1 20); do [[ -f "$OUT" ]] && { echo "$OUT"; exit 0; }; sleep 0.5; done
echo "No snapshot written (is Slop Cleaner running?)" >&2; exit 1
