#!/usr/bin/env node
// mFRAMES — serveur MCP (stdio, sans dépendance). Relie un agent IA au pont local de mFRAMES :
// l'agent publie un document, lit les retours du prestataire / client, y répond, les marque résolus.
// Variables : MFRAMES_DATA_DIR (dossier de données, sinon ~/Library/Application Support/mFRAMES[ DEV]).
import fs from "node:fs"; import os from "node:os"; import path from "node:path"; import readline from "node:readline";

function bridge() {
  const dirs = process.env.MFRAMES_DATA_DIR ? [process.env.MFRAMES_DATA_DIR]
    : ["mFRAMES", "mFRAMES DEV"].map(n => path.join(os.homedir(), "Library/Application Support", n));
  for (const d of dirs) { try { return JSON.parse(fs.readFileSync(path.join(d, "bridge.json"), "utf8")); } catch {} }
  throw new Error("Le pont local de mFRAMES est éteint : l'activer dans Réglages > Intégrations.");
}
async function api(method, p, body) {
  const b = bridge();
  const r = await fetch(`http://127.0.0.1:${b.port}${p}`, { method, headers: { Authorization: `Bearer ${b.token}`, "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
  const t = await r.text();
  if (!r.ok) throw new Error(`mFRAMES ${r.status} : ${t}`);
  try { return JSON.parse(t); } catch { return t; }
}
const q = o => Object.entries(o).filter(([, v]) => v !== undefined).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join("&");
const S = (props, required = []) => ({ type: "object", properties: props, required });

const HINT = "PROCHAINE ÉTAPE OBLIGATOIRE : lancer maintenant en arrière-plan (Bash run_in_background) `node " + new URL("./mframes-wait.mjs", import.meta.url).pathname + " <seq déjà traité, 0 au début>` puis terminer le tour ; l'utilisateur n'a rien à écrire dans Claude : dès qu'il clique « Envoyer à Claude », la commande se termine et te réveille. Alors lire mframes_get_feedback et corriger.";
const withHint = t => { const run = t.run; t.run = async a => { const r = await run(a); return (r && typeof r === "object" && !Array.isArray(r)) ? { ...r, prochaine_etape: HINT } : { resultat: r, prochaine_etape: HINT }; }; return t; };

const tools = [
  { name: "mframes_list_projects", description: "Liste les projets de review (id, nom, client, type, versions).", inputSchema: S({}), run: () => api("GET", "/v1/projects") },
  { name: "mframes_current", description: "Projet et version actuellement ouverts dans mFRAMES.", inputSchema: S({}), run: () => api("GET", "/v1/current") },
  { name: "mframes_publish_document", description: "Publie un fichier (vidéo, image, PDF, PSD/AI) comme NOUVEAU projet de review que l'utilisateur pourra annoter.", inputSchema: S({ path: { type: "string", description: "Chemin absolu du fichier" }, name: { type: "string" }, client: { type: "string" } }, ["path"]), run: a => api("POST", "/v1/projects", a) },
  { name: "mframes_publish_version", description: "Publie une nouvelle version (V2, V3…) d'un projet existant, après avoir pris en compte les retours.", inputSchema: S({ projectID: { type: "string" }, path: { type: "string", description: "Chemin absolu du fichier" } }, ["projectID", "path"]), run: a => api("POST", `/v1/projects/${a.projectID}/versions`, { path: a.path }) },
  { name: "mframes_get_feedback", description: "Lit les retours (annotations) d'une version : texte, horodatage (secondes) ou page, position 0…1, statut open/resolved, réponses. 'since' = dernier lamport déjà lu, pour ne recevoir que le nouveau.", inputSchema: S({ versionID: { type: "string" }, since: { type: "number" } }), run: a => api("GET", "/v1/annotations?" + q({ versionID: a.versionID, since: a.since })) },
  { name: "mframes_reply", description: "Répond à un retour (visible par l'utilisateur dans le fil de l'annotation).", inputSchema: S({ annotationID: { type: "string" }, text: { type: "string" }, author: { type: "string", description: "Nom affiché, défaut « Agent IA »" } }, ["annotationID", "text"]), run: a => api("POST", `/v1/annotations/${a.annotationID}/replies`, { text: a.text, author: a.author }) },
  { name: "mframes_set_status", description: "Marque un retour comme traité (resolved) ou à nouveau ouvert (open).", inputSchema: S({ annotationID: { type: "string" }, status: { type: "string", enum: ["open", "resolved"] } }, ["annotationID", "status"]), run: a => api("POST", `/v1/annotations/${a.annotationID}/status`, { status: a.status }) },
  { name: "mframes_get_submissions", description: "Envois du prestataire (bouton « Envoyer à Claude ») : numéro (seq), projet, version, nombre de retours. 'since' = dernier seq déjà traité. Lire ensuite les retours avec mframes_get_feedback(versionID).", inputSchema: S({ since: { type: "number" } }), run: a => api("GET", "/v1/submissions?since=" + (a.since || 0)) },
  { name: "mframes_wait_for_submission", description: "ATTEND (jusqu'à 55 s) que l'utilisateur clique « Envoyer à Claude » dans mFRAMES ; renvoie les nouveaux envois, ou [] au bout du délai (rappeler alors l'outil). À utiliser après avoir publié un média, pour recevoir les retours dès qu'ils sont envoyés.", inputSchema: S({ since: { type: "number" }, timeout: { type: "number" } }), run: async a => { const end = Date.now() + Math.min(a.timeout || 55, 55) * 1000; for (;;) { const r = await api("GET", "/v1/submissions?since=" + (a.since || 0)); if (r.length || Date.now() > end) return r; await new Promise(r => setTimeout(r, 1000)); } } },
  { name: "mframes_export_markers", description: "Exporte les retours d'une version en marqueurs (edl, fcpxml, premiere, aejsx, csv).", inputSchema: S({ versionID: { type: "string" }, format: { type: "string" }, fps: { type: "number" } }, ["versionID", "format"]), run: a => api("GET", "/v1/export?" + q(a)) },
];
for (const t of tools) if (/^mframes_publish_(document|version)$/.test(t.name)) withHint(t);

const send = m => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...m }) + "\n");
readline.createInterface({ input: process.stdin }).on("line", async line => {
  let m; try { m = JSON.parse(line); } catch { return; }
  if (m.id === undefined) return; // notification
  try {
    if (m.method === "initialize") return send({ id: m.id, result: { protocolVersion: m.params?.protocolVersion || "2024-11-05", capabilities: { tools: {} }, serverInfo: { name: "mframes", version: "1.0.0" } } });
    if (m.method === "ping") return send({ id: m.id, result: {} });
    if (m.method === "tools/list") return send({ id: m.id, result: { tools: tools.map(({ run, ...t }) => t) } });
    if (m.method === "tools/call") {
      const t = tools.find(x => x.name === m.params.name);
      if (!t) return send({ id: m.id, error: { code: -32602, message: "outil inconnu" } });
      try { const r = await t.run(m.params.arguments || {}); return send({ id: m.id, result: { content: [{ type: "text", text: typeof r === "string" ? r : JSON.stringify(r, null, 2) }] } }); }
      catch (e) { return send({ id: m.id, result: { isError: true, content: [{ type: "text", text: String(e.message || e) }] } }); }
    }
    send({ id: m.id, error: { code: -32601, message: "méthode inconnue" } });
  } catch (e) { send({ id: m.id, error: { code: -32603, message: String(e) } }); }
});
