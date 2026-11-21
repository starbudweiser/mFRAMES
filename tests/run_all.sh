#!/bin/zsh
# Tous les essais de mFRAMES, sans fenêtre : langues, modules, chiffrement du client web, session (transfert, coupure), relais, pont local, proxys, client navigateur.
cd "$(dirname "$0")/.."
BIN="${1:-mFRAMES DEV.app/Contents/MacOS/mFRAMES}"
fail=0
run() { printf '\n== %s\n' "$1"; shift; "$@" || { echo "ÉCHEC : $1"; fail=1; }; }
run "Langues" ./tests/check_l10n.sh
run "Modules d'intégration (syntaxe)" ./tests/integrations_test.sh
run "Chiffrement du client web (JS contre Node)" node tests/web_crypto_test.js
run "Serveur MCP (faux pont)" node tests/mcp_test.js
run "Session chiffrée, transfert, coupure et reprise" "$BIN" --selftest
run "Relais" ./tests/relay_test.sh "$BIN"
run "Pont local et exports de marqueurs" env MFRAMES_NO_KEYCHAIN=1 "$BIN" --selftest-bridge
run "Réseau (STUN, UPnP en lecture seule)" "$BIN" --selftest-net
printf 'P' > /tmp/mf-proxy.pdf; python3 -c "
from PIL import Image; Image.new('RGB',(4000,3000),(30,60,90)).save('/tmp/mf-grand.png')"
run "Proxys (image)" "$BIN" --make-proxy /tmp/mf-grand.png
run "Script After Effects (objets simulés, vrai pont)" ./tests/after_effects_test.sh "$BIN"
run "Hôte et client en deux processus (adresse réseau réelle)" ./tests/deux_processus.sh "$BIN"
run "Client navigateur (Chromium sans fenêtre)" python3 tests/web_e2e.py "$BIN"
[ $fail = 0 ] && echo "\nTOUS LES ESSAIS PASSENT" || echo "\nDES ESSAIS ÉCHOUENT"
exit $fail
