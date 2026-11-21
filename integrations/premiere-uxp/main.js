// mFRAMES — panneau Premiere Pro (UXP) : retours du client en marqueurs de la séquence active.
// À VALIDER dans Premiere Pro : les noms exacts de l'API UXP de marqueurs varient selon la version ; en cas d'écart le panneau le dit,
// et l'import « XML Premiere » (mFRAMES › Fichier › Exporter les marqueurs) fonctionne dans toutes les versions.
const storage = require("uxp").storage;
const log = (m) => (document.getElementById("log").textContent = m);

// Lit le fichier du pont local (écrit par mFRAMES) : édition normale, puis édition de développement. MFRAMES_BRIDGE_FILE : chemin de remplacement (essais).
async function bridge() {
  const fs = storage.localFileSystem;
  const home = require("os").homedir();
  const paths = [globalThis.MFRAMES_BRIDGE_FILE, home + "/Library/Application Support/mFRAMES/bridge.json", home + "/Library/Application Support/mFRAMES DEV/bridge.json"].filter(Boolean);
  for (const p of paths) {
    try { return JSON.parse(await (await fs.getEntryWithUrl("file://" + encodeURI(p))).read()); } catch (e) { /* suivant */ }
  }
  throw new Error("pont local introuvable : ouvrez mFRAMES et activez Réglages › Intégrations › pont local");
}
async function call(info, method, path, body) {
  const r = await fetch(`http://127.0.0.1:${info.port}${path}`, { method, headers: { Authorization: `Bearer ${info.token}`, "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
  return r.json();
}

async function importMarkers() {
    const info = await bridge();
    const ppro = require("premierepro");
    const project = await ppro.Project.getActiveProject();
    const sequence = await project.getActiveSequence();
    const cur = await call(info, "GET", "/v1/current");          // le projet et la version ouverts dans mFRAMES
    const version = { id: cur.versionID, number: cur.number };
    const annotations = await call(info, "GET", `/v1/annotations?versionID=${version.id}`);
    const markers = await ppro.Markers.getMarkers(sequence);
    let n = 0;
    // L'API exige l'accès verrouillé au projet : toutes les créations se font dans un seul bloc (annulable d'un coup).
    project.lockedAccess(() => {
      project.executeTransaction((ca) => {
        for (const a of annotations) {
          ca.addAction(markers.createAddMarkerAction(`${a.status === "resolved" ? "✓" : "●"} ${a.author}`, ppro.Marker.MARKER_TYPE_COMMENT, ppro.TickTime.createWithSeconds(a.time || 0), ppro.TickTime.createWithSeconds(0), a.text));
          n++;
        }
      }, "mFRAMES : retours du client");
    });
    return { n, number: version.number };
}
globalThis.mframesImport = importMarkers;
document.getElementById("import").onclick = async () => {
  try { const r = await importMarkers(); log(`${r.n} marqueur(s) ajouté(s) (version ${r.number}).`); }
  catch (e) { log("mFRAMES : " + e.message + "\nUtilisez l'export « XML Premiere » de mFRAMES en attendant."); }
};

document.getElementById("resolve").onclick = () => log("Passez les marqueurs en « résolu » dans mFRAMES ; cette synchronisation inverse arrive avec l'API UXP stable.");
