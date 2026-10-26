#!/bin/bash
# Opens the mac-rdp-connect menu bar app (building it first if needed) and
# follows its log. Permissions and settings are handled in the app.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/mac-rdp-connect.app
LOG="$HOME/Library/Logs/mac-rdp-connect.log"

# Rebuilding changes an ad-hoc signed app's identity and macOS forgets its
# permissions, so only build when there is no app yet.
[[ -d "$APP" ]] || ./scripts/bundle.sh

open "$APP"
echo "mac-rdp-connect is running in the menu bar."
echo "Following $LOG (Ctrl-C stops following, not the app)"
touch "$LOG"
exec tail -f "$LOG"
