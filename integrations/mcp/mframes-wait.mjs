#!/usr/bin/env node
// mFRAMES — attend un « Envoyer à Claude » et se termine alors en affichant les envois (JSON).
// Lancé par Claude en arrière-plan (Bash run_in_background) : sa fin réveille la session, sans
// aucune action de l'utilisateur dans Claude. Usage : node mframes-wait.mjs [since] [heures max, défaut 8]
import fs from "node:fs"; import os from "node:os"; import path from "node:path";
const since = Number(process.argv[2] || 0), end = Date.now() + Number(process.argv[3] || 8) * 3600e3;
const dirs = process.env.MFRAMES_DATA_DIR ? [process.env.MFRAMES_DATA_DIR] : ["mFRAMES", "mFRAMES DEV"].map(n => path.join(os.homedir(), "Library/Application Support", n));
const bridge = () => { for (const d of dirs) { try { return JSON.parse(fs.readFileSync(path.join(d, "bridge.json"), "utf8")); } catch {} } };
while (Date.now() < end) {
  try {
    const b = bridge();
    if (b) { const r = await fetch(`http://127.0.0.1:${b.port}/v1/submissions?since=${since}`, { headers: { Authorization: `Bearer ${b.token}` } }); const j = await r.json(); if (Array.isArray(j) && j.length) { console.log(JSON.stringify(j)); process.exit(0); } }
  } catch {}
  await new Promise(r => setTimeout(r, 1500));
}
console.log("[]"); process.exit(0);
