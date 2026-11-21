// mFRAMES — client navigateur : même protocole chiffré que l'app cliente (trames AES-GCM sur WebSocket), copie locale complète, retours hors ligne.
"use strict";
const $ = (id) => document.getElementById(id);
const UP = (s) => String(s).toUpperCase();
const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");
const uuidOf = (b) => { const h = hex(b); return UP(`${h.slice(0,8)}-${h.slice(8,12)}-${h.slice(12,16)}-${h.slice(16,20)}-${h.slice(20)}`); };
const uuidBytes = (u) => Uint8Array.from(u.replace(/-/g, "").match(/../g), (x) => parseInt(x, 16));
const b64 = (u8) => { let s = ""; u8.forEach((c) => (s += String.fromCharCode(c))); return btoa(s); };
const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
const b64url = (s) => unb64(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
const newId = () => UP(crypto.randomUUID ? crypto.randomUUID() : hex(crypto.getRandomValues(new Uint8Array(16))).replace(/(.{8})(.{4})(.{4})(.{4})(.{12})/, "$1-$2-$3-$4-$5"));
const dec = new TextDecoder(), enc = new TextEncoder();

// ---------- langue : celle du navigateur (première langue préférée prise en charge), sinon l'anglais ; « lang=fr|en|es|it » dans le lien pour les essais ----------
const I18N = {
  fr: { join: "Ouvrez le lien d'invitation reçu de votre prestataire.", follow: "Suivre", waiting: "En attente du média…", pin: "Épingle", zone: "Zone", feedback: "Retours",
        openCount: "{0} ouverts", placeholder: "Répondre ou annoter…", send: "Envoyer", askName: "Votre nom (visible de votre prestataire) :", defaultName: "Client",
        lost: "Connexion perdue — vos retours sont conservés, reconnexion…", synced: "Synchronisé", offline: "hors ligne", localCopy: "Copie locale {0} %",
        you: "Vous", open: "Ouvert", resolved: "Résolu" },
  en: { join: "Open the invitation link you received from your provider.", follow: "Follow", waiting: "Waiting for the media…", pin: "Pin", zone: "Zone", feedback: "Feedback",
        openCount: "{0} open", placeholder: "Reply or annotate…", send: "Send", askName: "Your name (visible to your provider):", defaultName: "Client",
        lost: "Connection lost — your feedback is kept, reconnecting…", synced: "Synced", offline: "offline", localCopy: "Local copy {0}%",
        you: "You", open: "Open", resolved: "Resolved" },
  es: { join: "Abre el enlace de invitación recibido de tu proveedor.", follow: "Seguir", waiting: "Esperando el archivo…", pin: "Chincheta", zone: "Zona", feedback: "Comentarios",
        openCount: "{0} abiertos", placeholder: "Responder o anotar…", send: "Enviar", askName: "Tu nombre (visible para tu proveedor):", defaultName: "Cliente",
        lost: "Conexión perdida — tus comentarios se conservan, reconectando…", synced: "Sincronizado", offline: "sin conexión", localCopy: "Copia local {0} %",
        you: "Tú", open: "Abierto", resolved: "Resuelto" },
  it: { join: "Apri il link d'invito ricevuto dal tuo fornitore.", follow: "Segui", waiting: "In attesa del file…", pin: "Spilla", zone: "Area", feedback: "Commenti",
        openCount: "{0} aperti", placeholder: "Rispondi o annota…", send: "Invia", askName: "Il tuo nome (visibile al tuo fornitore):", defaultName: "Cliente",
        lost: "Connessione persa — i tuoi commenti sono conservati, riconnessione…", synced: "Sincronizzato", offline: "offline", localCopy: "Copia locale {0}%",
        you: "Tu", open: "Aperto", resolved: "Risolto" },
};
const LANG = (() => {
  const forced = new URLSearchParams(location.hash.slice(1)).get("lang");
  if (forced && I18N[forced]) return forced;
  for (const l of (navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language || "en"])) { const c = String(l).slice(0, 2).toLowerCase(); if (I18N[c]) return c; }
  return "en";
})();
const T = (k, ...a) => a.reduce((s, v, i) => s.replace("{" + i + "}", v), I18N[LANG][k] ?? I18N.en[k] ?? k);
document.documentElement.lang = LANG;
for (const el of document.querySelectorAll("[data-i18n]")) el.textContent = T(el.dataset.i18n);
for (const el of document.querySelectorAll("[data-i18n-title]")) el.title = T(el.dataset.i18nTitle);
for (const el of document.querySelectorAll("[data-i18n-ph]")) el.placeholder = T(el.dataset.i18nPh);
$("open").textContent = T("openCount", 0);

const S = { key: null, ws: null, sendN: 0, recvN: 0, code: "", me: null, ops: new Map(), annotations: new Map(), messages: new Map(), clock: 0, seq: 0,
            projects: [], offers: new Map(), chunks: new Map(), files: new Map(), progress: new Map(), versionID: null, tool: "pin", selected: null, attempt: 0, hostCursor: null, drag: null };

// ---------- invitation ----------
const frag = new URLSearchParams(location.hash.slice(1));
if (!frag.get("c") || !frag.get("k")) { $("join").classList.remove("hidden"); }
else { S.code = frag.get("c"); start(); }

async function start() {
  S.key = await MFCrypto.deriveKey(b64url(frag.get("k")), S.code);
  const saved = JSON.parse(localStorage.getItem("mframes:author:" + S.code) || "null");
  S.me = saved || { id: "WEB-" + newId(), name: (localStorage.getItem("mframes:name") || prompt(T("askName"), "") || T("defaultName")), colorIndex: Math.floor(Math.random() * 6) };
  localStorage.setItem("mframes:author:" + S.code, JSON.stringify(S.me)); localStorage.setItem("mframes:name", S.me.name);
  for (const op of JSON.parse(localStorage.getItem("mframes:ops:" + S.code) || "[]")) { S.ops.set(op.id, op); S.clock = Math.max(S.clock, op.lamport); if (op.author === S.me.id) S.seq = Math.max(S.seq, op.seq); apply(op); }
  $("app").classList.remove("hidden"); render(); connect();
}

// ---------- transport ----------
function connect() {
  const ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/ws`);
  ws.binaryType = "arraybuffer"; S.ws = ws; S.sendN = 0; S.recvN = 0;
  ws.onopen = () => { send({ hello: { _0: { peer: { name: S.me.name, role: "client", authorID: S.me.id }, have: have() } } }); };
  ws.onmessage = async (e) => {
    const plain = await MFCrypto.open(S.key, new Uint8Array(e.data));
    if (!plain || plain.length < 9) { ws.close(); return; }
    const n = new DataView(plain.buffer, plain.byteOffset + 1, 8).getBigUint64(0);
    if (Number(n) !== S.recvN + 1) { ws.close(); return; }
    S.recvN = Number(n);
    const body = plain.subarray(9);
    if (plain[0] === 0) onWire(JSON.parse(dec.decode(body))); else if (plain[0] === 1) onChunk(uuidOf(body.subarray(0, 16)), new DataView(body.buffer, body.byteOffset + 16, 4).getUint32(0), body.subarray(20));
  };
  ws.onclose = () => { banner(T("lost"), false); setPeer(false); S.attempt++; setTimeout(connect, Math.min(1000 * 2 ** Math.min(S.attempt - 1, 4), 15000)); };
}
async function send(wire) {
  if (!S.ws || S.ws.readyState !== 1) return;
  const body = enc.encode(JSON.stringify(wire)), plain = new Uint8Array(9 + body.length);
  plain[0] = 0; new DataView(plain.buffer).setBigUint64(1, BigInt(++S.sendN)); plain.set(body, 9);
  S.ws.send(await MFCrypto.seal(S.key, plain));
}

// ---------- protocole ----------
function have() { const h = {}; for (const o of S.ops.values()) h[o.author] = Math.max(h[o.author] || 0, o.seq); return h; }
function onWire(w) {
  const [kind] = Object.keys(w), v = w[kind] && w[kind]._0;
  if (kind === "hello") {
    S.attempt = 0; banner(T("synced"), true, 1500); setPeer(true, v.peer.name);
    const missing = [...S.ops.values()].filter((o) => o.seq > (v.have[o.author] || 0));
    if (missing.length) send({ ops: { _0: missing.map(wireOp) } });
  } else if (kind === "ops") { let n = 0; for (const o of v) n += receiveOp(o) ? 1 : 0; if (n) render(); }
  else if (kind === "projects") onProjects(v);
  else if (kind === "cursor") onCursor(v);
  else if (kind === "fileDone") finishFile(UP(v));
  else if (kind === "bye") S.ws.close();
}
const wireOp = (o) => ({ id: o.id, author: o.author, seq: o.seq, lamport: o.lamport, kind: o.kind, payload: o.payload });
function receiveOp(o) { o.id = UP(o.id); if (S.ops.has(o.id)) return false; S.ops.set(o.id, o); S.clock = Math.max(S.clock, o.lamport); persist(); apply(o); return true; }
function apply(o) {
  const v = JSON.parse(dec.decode(unb64(o.payload))); v.id = UP(v.id); v.versionID = UP(v.versionID); if (v.annotationID) v.annotationID = UP(v.annotationID);
  const map = o.kind === "annotation" ? S.annotations : S.messages, old = map.get(v.id);
  if (!old || old.lamport < v.lamport || (old.lamport === v.lamport && old.id < v.id)) map.set(v.id, v);
}
function persist() { localStorage.setItem("mframes:ops:" + S.code, JSON.stringify([...S.ops.values()])); }
function record(kind, value) {
  S.clock++; S.seq++; value.lamport = S.clock;
  const op = { id: newId(), author: S.me.id, seq: S.seq, lamport: S.clock, kind, payload: b64(enc.encode(JSON.stringify(value))) };
  S.ops.set(op.id, op); persist(); apply(op); render();
  send({ ops: { _0: [wireOp(op)] } });
}
const iso = () => new Date().toISOString().replace(/\.\d+Z$/, "Z");

// ---------- projets et fichiers ----------
function onProjects(infos) {
  S.projects = infos.map((p) => ({ ...p, id: UP(p.id), versions: p.versions.map((v) => ({ ...v, id: UP(v.id), file: v.file && { ...v.file, versionID: UP(v.file.versionID) } })) }));
  if (!S.versionID || !S.projects.some((p) => p.versions.some((v) => v.id === S.versionID))) S.versionID = S.projects[0] && S.projects[0].versions.reduce((a, b) => (a.number > b.number ? a : b)).id;
  for (const p of S.projects) for (const v of p.versions) if (v.file && !S.files.has(v.id) && !S.offers.has(v.id)) {
    S.offers.set(v.id, v.file); S.chunks.set(v.id, []); send({ fileRequest: { _0: { versionID: v.id, fromChunk: S.chunks.get(v.id).length } } });
  } else if (v.file && S.offers.has(v.id) && !S.files.has(v.id)) send({ fileRequest: { _0: { versionID: v.id, fromChunk: (S.chunks.get(v.id) || []).length } } });   // reprise après coupure
  render();
}
function onChunk(id, idx, data) {
  const list = S.chunks.get(id), offer = S.offers.get(id);
  if (!list || !offer || idx !== list.length) return;      // seulement le bloc suivant : un doublon après reprise est ignoré
  list.push(new Uint8Array(data));
  S.progress.set(id, Math.min(1, list.length * offer.chunkSize / Math.max(offer.size, 1)));
  if (id === S.versionID) { $("prog").style.width = S.progress.get(id) * 100 + "%"; $("progtxt").textContent = T("localCopy", Math.round(S.progress.get(id) * 100)); }
}
async function finishFile(id) {
  const offer = S.offers.get(id), list = S.chunks.get(id); if (!offer || !list) return;
  const all = new Uint8Array(list.reduce((n, c) => n + c.length, 0)); let o = 0; for (const c of list) { all.set(c, o); o += c.length; }
  const sum = hex(await MFCrypto.sha256(all));
  if (all.length !== offer.size || sum !== offer.sha256) { S.chunks.set(id, []); send({ fileRequest: { _0: { versionID: id, fromChunk: 0 } } }); return; }   // copie altérée : on repart de zéro
  const ext = offer.name.split(".").pop().toLowerCase();
  const type = { mp4: "video/mp4", jpg: "image/jpeg", jpeg: "image/jpeg", png: "image/png", pdf: "application/pdf" }[ext] || "application/octet-stream";
  S.files.set(id, URL.createObjectURL(new Blob([all], { type }))); S.progress.set(id, 1); S.chunks.delete(id);
  render();
}
function onCursor(c) {
  S.hostCursor = c; if (!$("follow").checked) return;
  const v = document.querySelector("video"); if (!v) return;
  if (Math.abs(v.currentTime - c.time) > 0.4) v.currentTime = c.time;
  if (c.playing && v.paused) v.play().catch(() => {}); else if (!c.playing && !v.paused) v.pause();
}

// ---------- affichage ----------
function banner(t, ok, ms) { const b = $("banner"); b.textContent = t; b.className = "banner" + (ok ? " ok" : ""); if (ms) setTimeout(() => b.classList.add("hidden"), ms); }
function setPeer(on, name) { $("peerdot").className = "dot" + (on ? " on" : ""); $("peername").textContent = on ? name : T("offline"); }
const curVersion = () => { for (const p of S.projects) for (const v of p.versions) if (v.id === S.versionID) return { p, v }; return null; };

function render() {
  const cv = curVersion();
  if (cv) { $("title").textContent = `${cv.p.name} · V${cv.v.number}`; $("subtitle").textContent = cv.p.client || cv.p.kind; $("kindtile").textContent = { video: "▶", image: "▣", pdf: "≣", design: "◧" }[cv.p.kind] || "●"; }
  const stage = $("stage"), url = cv && S.files.get(cv.v.id);
  if (cv && url) {
    let m = stage.querySelector(".media");
    if (!m || m.dataset.v !== cv.v.id) {
      stage.innerHTML = ""; m = document.createElement("div"); m.className = "media"; m.dataset.v = cv.v.id;
      const name = (cv.v.file && cv.v.file.name || "").toLowerCase();
      if (name.endsWith(".mp4")) m.innerHTML = `<video src="${url}" controls playsinline></video>`;
      else if (name.endsWith(".pdf")) m.innerHTML = `<iframe src="${url}"></iframe>`;
      else m.innerHTML = `<img src="${url}" draggable="false">`;
      stage.appendChild(m); wireMedia(m);
    }
    for (const el of m.querySelectorAll(".pin,.zone")) el.remove();
    const list = [...S.annotations.values()].filter((a) => a.versionID === cv.v.id && !a.deleted).sort((a, b) => (a.time || 0) - (b.time || 0) || a.lamport - b.lamport);
    const isVideo = name_(cv).endsWith(".mp4"), vid = m.querySelector("video");
    list.forEach((a, i) => {
      if (isVideo && vid && a.time != null && Math.abs(a.time - vid.currentTime) > 4 && S.selected !== a.id) return;
      if (a.kind === "zone") { const z = document.createElement("div"); z.className = "zone"; Object.assign(z.style, { left: a.x * 100 + "%", top: a.y * 100 + "%", width: a.w * 100 + "%", height: a.h * 100 + "%" }); m.appendChild(z); }
      const p = document.createElement("div"); p.className = "pin" + (a.status === "resolved" ? " res" : "") + (S.selected === a.id ? " sel" : ""); p.textContent = i + 1;
      Object.assign(p.style, { left: a.x * 100 + "%", top: a.y * 100 + "%" }); p.onclick = (e) => { e.stopPropagation(); select(a); }; m.appendChild(p);
    });
  } else if (!url) {
    if (!stage.querySelector(".empty")) { stage.innerHTML = ""; stage.appendChild($("empty")); }
    $("empty").classList.remove("hidden");
  }
  renderMessages(cv);
}
const name_ = (cv) => ((cv.v.file && cv.v.file.name) || "").toLowerCase();

function renderMessages(cv) {
  const box = $("msgs"); box.innerHTML = ""; if (!cv) return;
  const ann = [...S.annotations.values()].filter((a) => a.versionID === cv.v.id && !a.deleted).sort((a, b) => (a.time || 0) - (b.time || 0) || a.lamport - b.lamport);
  const num = new Map(ann.map((a, i) => [a.id, i + 1]));
  const items = [...ann.map((a) => ({ a, l: a.lamport })), ...[...S.messages.values()].filter((m) => m.versionID === cv.v.id && !m.deleted).map((m) => ({ m, l: m.lamport }))].sort((x, y) => x.l - y.l);
  $("open").textContent = T("openCount", ann.filter((a) => a.status === "open").length);
  for (const it of items) {
    const x = it.a || it.m, mine = x.author.id === S.me.id, d = document.createElement("div"); d.className = "msg" + (mine ? " me" : "");
    const who = document.createElement("div"); who.className = "who"; who.textContent = mine ? T("you") : x.author.name; d.appendChild(who);
    const b = document.createElement("div"); b.className = "bub"; b.textContent = x.text || (it.a ? `${it.a.kind === "zone" ? T("zone") : T("pin")} ${num.get(it.a.id)}` : ""); d.appendChild(b);
    if (it.a) {
      const a = it.a, tc = a.time != null ? fmt(a.time) : (a.kind === "zone" ? T("zone") : T("pin")) + " " + num.get(a.id);
      const c1 = document.createElement("button"); c1.className = "chip"; c1.textContent = "◷ " + tc; c1.onclick = () => select(a);
      const c2 = document.createElement("button"); c2.className = "chip " + (a.status === "open" ? "o" : "g"); c2.textContent = a.status === "open" ? T("open") : T("resolved");
      c2.onclick = () => record("annotation", { ...a, status: a.status === "open" ? "resolved" : "open" });
      const row = document.createElement("div"); row.append(c1, c2); d.appendChild(row);
    }
    box.appendChild(d);
  }
  box.scrollTop = box.scrollHeight;
}
const fmt = (t) => `${String(Math.floor(t / 60)).padStart(2, "0")}:${String(Math.floor(t % 60)).padStart(2, "0")}:${String(Math.floor((t % 1) * 25)).padStart(2, "0")}`;
function select(a) { S.selected = a.id; const v = document.querySelector("video"); if (v && a.time != null) v.currentTime = a.time; render(); }

function wireMedia(m) {
  const target = m.querySelector("img,video,iframe"); if (!target || target.tagName === "IFRAME") return;
  const norm = (e) => { const r = target.getBoundingClientRect(); return { x: Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)), y: Math.min(1, Math.max(0, (e.clientY - r.top) / r.height)) }; };
  m.addEventListener("pointerdown", (e) => { if (e.target.classList.contains("pin") || (target.tagName === "VIDEO" && e.offsetY > target.clientHeight - 48)) return; S.drag = norm(e); });
  m.addEventListener("pointerup", (e) => {
    if (!S.drag) return; const s = S.drag, n = norm(e); S.drag = null;
    const cv = curVersion(), vid = m.querySelector("video"), moved = Math.hypot(n.x - s.x, n.y - s.y) > 0.01;
    const base = { id: newId(), versionID: cv.v.id, author: S.me, deleted: false, created: iso(), text: "", status: "open", w: 0, h: 0 };
    if (vid) base.time = vid.currentTime;
    const a = S.tool === "zone" && moved ? { ...base, kind: "zone", x: Math.min(s.x, n.x), y: Math.min(s.y, n.y), w: Math.abs(n.x - s.x), h: Math.abs(n.y - s.y) } : { ...base, kind: "pin", x: s.x, y: s.y };
    S.selected = a.id; record("annotation", a);
  });
  const v = m.querySelector("video"); if (v) v.addEventListener("timeupdate", () => { render(); });
}

$("tpin").onclick = () => { S.tool = "pin"; $("tpin").classList.add("on"); $("tzone").classList.remove("on"); };
$("tzone").onclick = () => { S.tool = "zone"; $("tzone").classList.add("on"); $("tpin").classList.remove("on"); };
$("form").onsubmit = (e) => {
  e.preventDefault(); const t = $("text").value.trim(), cv = curVersion(); if (!t || !cv) return;
  const m = { id: newId(), versionID: cv.v.id, author: S.me, text: t, deleted: false, created: iso() };
  if (S.selected && S.annotations.has(S.selected)) m.annotationID = S.selected;
  record("message", m); $("text").value = "";
};
window.__mframes = S;   // pour les essais automatiques
