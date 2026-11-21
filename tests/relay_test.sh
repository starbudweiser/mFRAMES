#!/bin/zsh
# Essai du relais : lance mframes-relay en local, puis hôte et client passent par lui (sans fenêtre).
cd "$(dirname "$0")/.."
BIN="${1:-mFRAMES DEV.app/Contents/MacOS/mFRAMES}"
PORT=$((20000 + RANDOM % 20000))
python3 relay/mframes-relay.py --host 127.0.0.1 --port $PORT >/tmp/mframes-relay.log 2>&1 &
RP=$!; sleep 1
"$BIN" --selftest-relay 127.0.0.1:$PORT; rc=$?
kill $RP 2>/dev/null
exit $rc
