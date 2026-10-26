#!/bin/bash
# Starts the RDP server as mac-rdp-connect.app, so macOS privacy permissions
# belong to mac-rdp-connect rather than this terminal, and follows its log.
# Extra arguments are passed to `serve`, e.g. ./scripts/run.sh --keys windowsShortcuts
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/mac-rdp-connect.app
LOG="$HOME/Library/Logs/mac-rdp-connect.log"

# Rebuilding changes an ad-hoc signed app's identity and macOS forgets its
# permissions, so only build when there is no app yet.
[[ -d "$APP" ]] || ./scripts/bundle.sh

pkill -f "$APP/Contents/MacOS/mac-rdp-connect serve" 2>/dev/null || true
: > "$LOG"
open -n "$APP" --stdout "$LOG" --stderr "$LOG" --args serve "$@"
echo "mac-rdp-connect started. Stop it with: pkill -f mac-rdp-connect"
echo "Following $LOG (Ctrl-C stops following, not the server)"
exec tail -f "$LOG"
