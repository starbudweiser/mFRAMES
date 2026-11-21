# Intégrations mFRAMES

Les logiciels de montage parlent à mFRAMES par le **pont local** : API JSON `/v1` sur `127.0.0.1`, jeton obligatoire, désactivée par défaut (Réglages › Intégrations). Le port et le jeton sont dans `~/Library/Application Support/mFRAMES/bridge.json` quand le pont est actif.

| Logiciel | Fourni | Comment |
| --- | --- | --- |
| DaVinci Resolve | Scripts Python : importer les retours en marqueurs (et renvoyer les « verts »), envoyer la timeline comme nouvelle version | `resolve/` → `…/DaVinci Resolve/Fusion/Scripts/Edit/` |
| After Effects | Script / panneau ScriptUI : marqueurs de la composition | `after-effects/` → `Scripts/ScriptUI Panels/` |
| Premiere Pro | Panneau UXP (essayé dans Premiere Pro 2027 : 3 marqueurs importés) ; sinon import « XML Premiere » | `premiere-uxp/` |
| Final Cut Pro | Export FCPXML (marqueurs) | Voir `final-cut-pro/` |

Sans module : **Fichier › Exporter les marqueurs** donne EDL (Resolve), FCPXML (Final Cut Pro, Resolve), XML Premiere, script After Effects et CSV.

## API v1
`GET /v1/status` · `GET /v1/current` (projet et version ouverts dans mFRAMES) · `GET /v1/projects` · `GET /v1/annotations?versionID=…&since=<lamport>` · `GET /v1/export?versionID=…&format=edl|fcpxml|premiere|aejsx|csv&fps=25` · `POST /v1/annotations/<id>/status {"status":"resolved"|"open"}` · `POST /v1/projects/<id>/versions {"path":"…"}`. En-tête `Authorization: Bearer <jeton>` ; l'hôte doit être `127.0.0.1` ou `localhost`.

## État de validation (16/11/2026)
- **DaVinci Resolve 21** : essayé pour de bon (import des retours, renvoi d'un statut « résolu », rendu envoyé comme nouvelle version). L'import d'un FCPXML par Resolve crée la timeline sans les marqueurs : pour Resolve, utilisez les scripts.
- **After Effects** : logique essayée avec des objets simulés contre le vrai pont ; pas essayée dans After Effects.
- **Premiere Pro** : panneau UXP validé dans Premiere Pro 2027 (lecture du pont, création des marqueurs sur la séquence active) ; permissions réseau « all » (port du pont variable) et accès fichiers pour lire `bridge.json`. **Final Cut Pro** : non installé ; export FCPXML non validé.
- L'API et les exports sont couverts par `mFRAMES --selftest-bridge` ; la syntaxe des modules par `tests/integrations_test.sh`.

**After Effects** : validé dans After Effects 2027 (aerender seul, sans fenêtre) : 3 marqueurs importés depuis le vrai pont ; le script Startup `zz_silent_job.jsx` n'est qu'un lanceur d'essai, absent de l'installation du produit.

## Serveur MCP — retours à un agent IA

`integrations/mcp/mframes-mcp.mjs` (Node, sans dépendance) relie un agent (Claude Code, Claude Desktop…) au pont local : l'agent **publie** un document ou une version, **lit** tes retours horodatés, y **répond** et les **marque résolus**. Activer le pont dans Réglages > Intégrations, puis :

```
claude mcp add mframes -- node /chemin/vers/mFRAMES/integrations/mcp/mframes-mcp.mjs
```

Outils : `mframes_list_projects`, `mframes_current`, `mframes_publish_document`, `mframes_publish_version`, `mframes_get_feedback`, `mframes_reply`, `mframes_set_status`, `mframes_export_markers`.

Envoi des retours : le bouton **Envoyer à Claude** (en-tête de « Retours ») enregistre un envoi ; l'agent le reçoit avec `mframes_wait_for_submission` (attente jusqu'à 55 s, à rappeler en boucle) ou `mframes_get_submissions`, puis lit les retours avec `mframes_get_feedback`.
