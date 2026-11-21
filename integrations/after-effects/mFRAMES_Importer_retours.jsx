// mFRAMES — After Effects : ajoute les retours du client comme marqueurs de la composition active.
// Installation : copier dans  Scripts/ScriptUI Panels/  (panneau dans le menu Fenêtre) ou lancer par Fichier › Scripts › Exécuter un fichier de script.
// Prérequis : mFRAMES ouvert, Réglages › Intégrations › pont local activé ; After Effects : Préférences › Scripts et expressions › Autoriser les scripts à écrire des fichiers et à accéder au réseau.
(function (thisObj) {
  var SUPPORT = Folder.userData.fsName; // ~/Library/Application Support
  function readInfo() {
    var names = ["mFRAMES", "mFRAMES DEV"];
    for (var i = 0; i < names.length; i++) {
      var f = new File(SUPPORT + "/" + names[i] + "/bridge.json");
      if (f.exists) { f.open("r"); var s = f.read(); f.close(); return s; }
    }
    return null;
  }
  function field(json, name) { var m = new RegExp('"' + name + '"\\s*:\\s*"?([^",}]+)"?').exec(json); return m ? m[1] : null; }
  function http(port, token, path) {
    var s = new Socket();
    if (!s.open("127.0.0.1:" + port, "BINARY")) throw new Error("mFRAMES : connexion impossible");
    s.write("GET " + path + " HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer " + token + "\r\nConnection: close\r\n\r\n");
    var out = ""; while (!s.eof) out += s.read(4096); s.close();
    try { out = decodeURIComponent(escape(out)); } catch (e) {} // la socket rend des octets : on les relit en UTF-8 (accents, ✓)
    var i = out.indexOf("\r\n\r\n"); return i < 0 ? out : out.substring(i + 4);
  }
  function importMarkers() {
    var info = readInfo();
    if (!info) { alert("mFRAMES : ouvrez mFRAMES et activez le pont local (Réglages › Intégrations)."); return; }
    var port = field(info, "port"), token = field(info, "token");
    var versionID = field(http(port, token, "/v1/current"), "versionID"); // le projet et la version ouverts dans mFRAMES
    if (!versionID) { alert("mFRAMES : ouvrez un projet dans mFRAMES."); return; }
    var script = http(port, token, "/v1/export?versionID=" + versionID + "&format=aejsx&fps=" + (app.project.activeItem ? app.project.activeItem.frameRate : 25));
    eval(script); // script généré par mFRAMES (marqueurs de la composition active)
  }
  var win = (thisObj instanceof Panel) ? thisObj : new Window("palette", "mFRAMES", undefined, { resizeable: true });
  win.orientation = "column"; win.alignChildren = "fill";
  var b = win.add("button", undefined, "Importer les retours du client");
  b.onClick = function () { try { importMarkers(); } catch (e) { alert(e.message); } };
  if (win instanceof Window) { win.center(); win.show(); } else { win.layout.layout(true); }
})(this);
