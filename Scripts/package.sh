#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) printf 'Use debug or release.\n' >&2; exit 2 ;; esac
version="$(<VERSION)"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'VERSION must contain a three-component release version.\n' >&2
    exit 2
fi
mkdir -p .build/clang-cache dist
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-"$PWD/.build/clang-cache"}"
swift build --disable-sandbox -c "$configuration" --product TokenLedger
binary_dir="$(swift build --disable-sandbox -c "$configuration" --show-bin-path)"
staging="$(mktemp -d "$PWD/dist/.package.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/Token Ledger.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/TokenLedger" "$app/Contents/MacOS/TokenLedger"
cp -R "$binary_dir/TokenLedger_TokenLedger.bundle" "$app/Contents/Resources/"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/"
swift Scripts/make-icon.swift "$app/Contents/Resources/TokenLedger.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.xpan0988.tokenledger</string>
<key>CFBundleName</key><string>Token Ledger</string>
<key>CFBundleDisplayName</key><string>Token Ledger</string>
<key>CFBundleExecutable</key><string>TokenLedger</string>
<key>CFBundleIconFile</key><string>TokenLedger</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

plutil -lint "$app/Contents/Info.plist"
identity="${TOKEN_LEDGER_SIGNING_IDENTITY:--}"
if [[ "$identity" == "-" ]]; then
    codesign --force --sign - "$app"
else
    codesign --force --options runtime --timestamp --sign "$identity" "$app"
fi
codesign --verify --strict "$app"
target="$PWD/dist/Token Ledger.app"
if [[ -e "$target" ]]; then mv "$target" "$staging/previous.app"; fi
if ! mv "$app" "$target"; then
    if [[ -e "$staging/previous.app" ]]; then mv "$staging/previous.app" "$target"; fi
    exit 1
fi
printf '%s\n' "$target"
