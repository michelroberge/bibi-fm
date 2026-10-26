#!/usr/bin/env bash
# Signs a bibi binary with "bibi local code signing" (see make-signing-identity.sh), so macOS keeps its privacy
# permissions across builds. Without that certificate the binary stays ad-hoc signed and this does nothing.
set -euo pipefail
BIN="$1"
NAME="bibi local code signing"
security find-certificate -c "$NAME" >/dev/null 2>&1 || exit 0
# Already signed with it: nothing to do.
if codesign -dvv "$BIN" 2>&1 | grep -q "Authority=$NAME"; then exit 0; fi
codesign --force --sign "$NAME" --identifier local.bibi "$BIN" 2>&1 | grep -v "replacing existing signature" >&2 || true
