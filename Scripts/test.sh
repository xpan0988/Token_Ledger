#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/clang-cache
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-"$PWD/.build/clang-cache"}"
developer="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ "$developer" == */CommandLineTools ]]; then
    # Apple's standalone Command Line Tools ship Swift Testing outside the SDK.
    frameworks="$developer/Library/Developer/Frameworks"
    interop="$developer/Library/Developer/usr/lib"
    swift test --disable-sandbox --disable-xctest --enable-swift-testing \
        -Xswiftc -F -Xswiftc "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
        -Xlinker -rpath -Xlinker "$interop" "$@"
else
    swift test --disable-xctest --enable-swift-testing "$@"
fi
