// Essai de la logique du script After Effects hors d'After Effects : objets ExtendScript simulés (Folder, File, Socket, CompItem, MarkerValue, app),
// la vraie API du pont répond. Contrôle l'analyse des réponses, la requête HTTP et les marqueurs créés. Ne prouve pas le comportement dans After Effects.
const fs = require("fs"), cp = require("child_process");
const support = process.argv[2];   // dossier contenant mFRAMES/bridge.json
const info = JSON.parse(fs.readFileSync(`${support}/mFRAMES/bridge.json`, "utf8"));
const markers = []; let alerts = [];
class Socket { open(a) { this.addr = a; this.buf = ""; this.pos = 0; return true; } write(s) { this.req = s; const path = s.split(" ")[1];
  const raw = cp.execFileSync("curl", ["-s", "-i", "-H", `Authorization: Bearer ${info.token}`, `http://${this.addr}${path}`]).toString("latin1");
  this.buf = raw.replace(/\r?\n/g, "\r\n"); }
  get eof() { return this.pos >= this.buf.length; } read(n) { const r = this.buf.substr(this.pos, n); this.pos += n; return r; } close() {} }
class File { constructor(p) { this.p = p; this.exists = fs.existsSync(p); } open() {} read() { return fs.readFileSync(this.p, "utf8"); } close() {} }
const Folder = { userData: { fsName: support } };
class CompItem { constructor() { this.frameRate = 25; this.markerProperty = { setValueAtTime: (t, m) => markers.push({ t, comment: m.comment }) }; } }
class MarkerValue { constructor(c) { this.comment = c; } }
const app = { project: { activeItem: new CompItem() }, beginUndoGroup() {}, endUndoGroup() {} };
const Window = function () {}; const Panel = function () {};
const src = fs.readFileSync(__dirname + "/../integrations/after-effects/mFRAMES_Importer_retours.jsx", "utf8");
// le script construit une fenêtre ; on récupère son bouton et on simule le clic
let click; const winObj = { orientation: "", alignChildren: "", add: () => ({ set onClick(f) { click = f; } }), layout: { layout() {} } };
const run = new Function("Socket", "File", "Folder", "CompItem", "MarkerValue", "app", "alert", "Panel", "Window", "eval2", src.replace("(this);", "(winObj);").replace("eval(script)", "eval2(script)"));
Object.setPrototypeOf(winObj, Panel.prototype);
let evalCode = "";
global.winObj = winObj;
run(Socket, File, Folder, CompItem, MarkerValue, app, (m) => alerts.push(m), Panel, Window, (s) => { evalCode = s; new Function("app", "CompItem", "MarkerValue", "alert", s)(app, CompItem, MarkerValue, (m) => alerts.push(m)); });
click();
let bad = 0; const ok = (c, m) => { console.log((c ? "  OK  " : "  ÉCHEC  ") + m); if (!c) bad++; };
ok(evalCode.includes("markerProperty.setValueAtTime"), "le script récupère les marqueurs du pont (version retrouvée par l'analyse de la réponse)");
ok(markers.length === 3 && markers[0].t === 2 && markers[1].t === 5.5 && markers[2].t === 9, "3 marqueurs aux bons instants (2 s, 5,5 s, 9 s)");
ok(markers[2].comment.startsWith("✓") && markers[0].comment.startsWith("●"), "résolu / ouvert distingués");
ok(alerts.some((a) => a.includes("3 marqueur")), "message final : " + alerts[alerts.length - 1]);
console.log(bad === 0 ? "TOUT PASSE" : `${bad} ÉCHEC(S)`); process.exit(bad === 0 ? 0 : 1);
