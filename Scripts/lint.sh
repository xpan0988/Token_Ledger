#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swiftformat Sources Tests Package.swift Scripts/make-icon.swift --lint --cache ignore
developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ "$developer" == */CommandLineTools ]]; then
    DYLD_FRAMEWORK_PATH="$developer/usr/lib" swiftlint lint --strict --no-cache
else
    swiftlint lint --strict --no-cache
fi
plutil -lint -- Sources/TokenLedger/Resources/{en,zh-Hans}.lproj/TokenLedger.strings
