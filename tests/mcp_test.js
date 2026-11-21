// Essai du serveur MCP : faux pont HTTP + dialogue JSON-RPC sur stdio.
const http = require("http"), fs = require("fs"), os = require("os"), path = require("path"), { spawn } = require("child_process");
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mfmcp-")); const seen = [];
const srv = http.createServer((req, res) => { let b = ""; req.on("data", d => b += d); req.on("end", () => {
  seen.push([req.method, req.url, req.headers.authorization, b]); res.setHeader("Content-Type", "application/json"); res.end(req.url.includes("/annotations?") ? "[{\"text\":\"ok\"}]" : "{\"ok\":true}"); }); });
srv.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(path.join(dir, "bridge.json"), JSON.stringify({ port: srv.address().port, token: "T0K" }));
  const p = spawn("node", ["integrations/mcp/mframes-mcp.mjs"], { env: { ...process.env, MFRAMES_DATA_DIR: dir } });
  const out = []; let buf = ""; p.stdout.on("data", d => { buf += d; let i; while ((i = buf.indexOf("\n")) >= 0) { out.push(JSON.parse(buf.slice(0, i))); buf = buf.slice(i + 1); } });
  const call = (id, method, params) => p.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  call(1, "initialize", { protocolVersion: "2024-11-05" }); call(2, "tools/list");
  call(3, "tools/call", { name: "mframes_reply", arguments: { annotationID: "A1", text: "Fait", author: "Claude" } });
  call(4, "tools/call", { name: "mframes_get_feedback", arguments: { versionID: "V1", since: 5 } });
  call(5, "tools/call", { name: "mframes_publish_document", arguments: { path: "/tmp/x.pdf", name: "N" } });
  setTimeout(() => {
    let bad = 0; const ck = (c, m) => { console.log((c ? "OK : " : "ÉCHEC : ") + m); if (!c) bad++; };
    ck(out.find(m => m.id === 1)?.result.serverInfo.name === "mframes", "initialize");
    ck(out.find(m => m.id === 2)?.result.tools.length === 10, "10 outils listés");
    ck(seen.some(s => s[0] === "POST" && s[1] === "/v1/annotations/A1/replies" && s[2] === "Bearer T0K" && s[3].includes("Claude")), "réponse envoyée avec jeton");
    ck(seen.some(s => s[1] === "/v1/annotations?versionID=V1&since=5"), "lecture des retours (depuis)");
    ck(seen.some(s => s[0] === "POST" && s[1] === "/v1/projects"), "publication d'un document");
    ck(out.find(m => m.id === 4)?.result.content[0].text.includes("ok"), "résultat renvoyé à l'agent");
    p.kill(); srv.close(); process.exit(bad ? 1 : 0);
  }, 1500);
});
