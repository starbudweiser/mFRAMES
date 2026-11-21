#!/bin/zsh
# Contrôle de syntaxe des modules d'intégration (leur comportement réel se confirme dans chaque logiciel).
cd "$(dirname "$0")/.."
rc=0
for f in integrations/resolve/*.py relay/mframes-relay.py; do python3 -m py_compile "$f" || rc=1; done
node --check integrations/premiere-uxp/main.js || rc=1
node -e "new Function(require('fs').readFileSync('integrations/after-effects/mFRAMES_Importer_retours.jsx','utf8'))" || rc=1
python3 -c "import json;json.load(open('integrations/premiere-uxp/manifest.json'))" || rc=1
[ $rc = 0 ] && echo "OK : modules d'intégration (syntaxe)" || echo "ÉCHEC"
exit $rc
