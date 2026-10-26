#!/bin/bash
# `swift test` with only the Command Line Tools installed: Swift Testing ships
# there but outside the default framework search path.
set -euo pipefail
cd "$(dirname "$0")/.."
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
if [[ -d "$F/Testing.framework" ]] && ! xcode-select -p | grep -q Xcode.app; then
    exec swift test -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" \
        -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
fi
exec swift test "$@"
