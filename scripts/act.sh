#!/usr/bin/env bash
# Debug: presses a suggestion's button by id in the running Slop Cleaner (same path as the card's button).
#   scripts/act.sh runaway:yes        (a suggestion card)
#   scripts/act.sh "row:<exact title>" (a row's Stop or Quit button)
set -euo pipefail
swift -e "import Foundation; DistributedNotificationCenter.default().postNotificationName(.init(\"slopcleaner.debug.act\"), object: \"$1\", userInfo: nil, deliverImmediately: true)"
