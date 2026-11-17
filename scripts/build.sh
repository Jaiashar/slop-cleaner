#!/usr/bin/env bash
# Builds Slop Cleaner, installs it to ~/Applications and opens it.
#
#   ./scripts/build.sh          build (Release) + install + open
#   ./scripts/build.sh test     run the unit tests
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodebuild >/dev/null 2>&1 || ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode is needed to build. Install it from the App Store, open it once, then run:"
  echo "  sudo xcode-select -s /Applications/Xcode.app"
  exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is needed to build. Install it with:  brew install xcodegen"
  exit 1
fi

xcodegen generate --quiet

# Sign with your Apple Development certificate if you have one; otherwise sign for this Mac only.
IDENT=$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development/{print $2; exit}' || true)
TEAM=""
if [[ -n "$IDENT" ]]; then
  TEAM=$(security find-certificate -Z -a -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
    | awk -F' = ' '/organizationalUnitName/{print $2; exit}' || true)
fi
if [[ -n "$IDENT" && -n "$TEAM" ]]; then
  SIGN=(DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_IDENTITY="$IDENT")
else
  echo "No Apple Development certificate found: signing for this Mac only (that's fine)."
  SIGN=(CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="")
fi

if [[ "${1:-}" == "test" ]]; then
  exec xcodebuild -project SlopCleaner.xcodeproj -scheme SlopCleaner -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath build/dd "${SIGN[@]}" test -quiet
fi

echo "Building Slop Cleaner…"
xcodebuild -project SlopCleaner.xcodeproj -scheme SlopCleaner -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/dd "${SIGN[@]}" build -quiet

APP="build/dd/Build/Products/Release/Slop Cleaner.app"
osascript -e 'tell application id "io.github.jaiashar.slopcleaner" to quit' >/dev/null 2>&1 || true
sleep 1
mkdir -p "$HOME/Applications"
ditto "$APP" "$HOME/Applications/Slop Cleaner.app.new"
rm -rf "$HOME/Applications/Slop Cleaner.app"
mv "$HOME/Applications/Slop Cleaner.app.new" "$HOME/Applications/Slop Cleaner.app"
open "$HOME/Applications/Slop Cleaner.app"
echo "Installed and opened ~/Applications/Slop Cleaner.app — look for the broom in your menu bar."
