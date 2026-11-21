#!/bin/zsh
# Logique du script After Effects (objets simulés) contre le vrai pont local.
cd "$(dirname "$0")/.."
BIN="${1:-mFRAMES DEV.app/Contents/MacOS/mFRAMES}"
D=$(mktemp -d); mkdir -p "$D/mFRAMES"; rm -f /tmp/mframes-bridge-stop
MFRAMES_DEMO_SELECT=spot MFRAMES_DEMO=1 MFRAMES_NO_KEYCHAIN=1 MFRAMES_DATA_DIR="$D/mFRAMES" MFRAMES_BRIDGE_PORT=$((30000 + RANDOM % 20000)) "$BIN" --bridge-demo 60 > "$D/log" 2>&1 &
sleep 4
node tests/after_effects_mock_test.js "$D"; rc=$?
touch /tmp/mframes-bridge-stop; wait; rm -rf "$D" /tmp/mframes-bridge-stop
exit $rc
