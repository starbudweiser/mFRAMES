#!/bin/zsh
# Hôte et client comme deux processus séparés, par l'adresse réseau réelle du Mac (pas la boucle locale) : retours, copie du proxy, annotation en retour.
# Sur deux Mac : lancer « mFRAMES --web-demo 120 » sur le premier, puis « mFRAMES --join-demo "<APP_LINK>" » sur le second.
cd "$(dirname "$0")/.."
BIN="${1:-mFRAMES DEV.app/Contents/MacOS/mFRAMES}"
rm -f /tmp/mframes-web-stop; LOG=$(mktemp)
MFRAMES_WEB_DIR=web "$BIN" --web-demo 90 > "$LOG" 2>&1 &
for i in {1..20}; do grep -q "^APP_LINK=.*&p=" "$LOG" && break; sleep 0.5; done
LINK=$(grep '^APP_LINK=' "$LOG" | cut -d= -f2-)
[ -n "$LINK" ] || { echo "ÉCHEC : l'hôte n'annonce pas de lien"; cat "$LOG"; kill %1 2>/dev/null; exit 1; }
timeout 90 "$BIN" --join-demo "$LINK"; rc=$?
sleep 1; grep -q "^CLIENT_ANNOTATION" "$LOG" && echo "  OK  l'hôte reçoit l'annotation du second processus" || { echo "  ÉCHEC  l'hôte n'a pas reçu l'annotation"; rc=1; }
touch /tmp/mframes-web-stop; wait; rm -f /tmp/mframes-web-stop "$LOG"
exit $rc
