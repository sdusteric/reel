#!/usr/bin/env bash
# Signing gate for the built Reel.app: hardened runtime, entitlements equal to
# resources/Reel.entitlements, and every nested Mach-O signed by the same team. The checks live in
# app-updates/tools/check-signing.sh.
#
#   scripts/check-signing.sh [path/Reel.app]
#
# Env: APP_UPDATES  the app-updates checkout (default: ../app-updates next to this repo)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_UPDATES="${APP_UPDATES:-$(cd "$REPO/.." && pwd)/app-updates}"
CHECK="$APP_UPDATES/tools/check-signing.sh"
[ -x "$CHECK" ] || { echo "missing $CHECK" >&2; exit 1; }
BUNDLE="${1:-$REPO/build/bundle/Reel.app}"
exec "$CHECK" "$BUNDLE" "$REPO/resources/Reel.entitlements"
