// mFRAMES — `mFRAMES --selftest` : essai sans fenêtre de la session chiffrée (annotation de bout en bout, position de lecture partagée,
// coupure et reprise, clé fausse refusée). Code de sortie 0 si tout passe.
import Foundation
import AppKit
import Network

enum SelfTest {
    static var failures = 0
    static func check(_ ok: Bool, _ what: String) { print((ok ? "  OK  " : "  ÉCHEC  ") + what); if !ok { failures += 1 } }

    /// Fait tourner la boucle d'événements jusqu'à ce que la condition soit vraie (ou délai dépassé).
    static func wait(_ seconds: Double = 8, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        return cond()
    }

    static func run() -> Int32 {
        setenv("MFRAMES_NO_KEYCHAIN", "1", 1)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mframes-selftest-\(UUID().uuidString)")
        let hostStore = ReviewStore(dir: tmp.appendingPathComponent("host"), authorName: "Stéphan", keyService: "test")
        let clientStore = ReviewStore(dir: tmp.appendingPathComponent("client"), authorName: "Marie", keyService: "test")
        let version = UUID()
        let inv = Invitation.new()
        print("Session de test — code \(inv.code)")

        let host = SessionEngine(role: .host, store: hostStore, invitation: inv)
        var cursorSeen: Cursor?
        let client = SessionEngine(role: .client, store: clientStore, invitation: inv)
        client.onCursor = { cursorSeen = $0 }
        guard let l = try? host.startHosting(port: 0, bonjour: false) else { print("Écoute impossible"); return 2 }
        _ = wait { host.invitation.port != nil }
        _ = l
        let port = host.invitation.port ?? 0
        check(port != 0, "l'hôte écoute sur un port libre (\(port))")

        client.connect(host: ProcessInfo.processInfo.environment["MFRAMES_TEST_HOST"] ?? "127.0.0.1", port: port)
        check(wait { client.state == .connected }, "le client se connecte et échange sa présentation")

        // 1. annotation du client → hôte
        let a = clientStore.addAnnotation(versionID: version, x: 0.46, y: 0.12, time: 5.02, text: "Le titre est trop petit")
        check(wait { hostStore.annotations[a.id] != nil }, "l'annotation du client arrive chez le prestataire")
        // 2. message de l'hôte → client
        let m = hostStore.addMessage(versionID: version, annotationID: a.id, text: "Je l'agrandis")
        check(wait { clientStore.messages[m.id] != nil }, "la réponse du prestataire arrive chez le client")
        // 3. position de lecture
        host.send(cursor: Cursor(versionID: version, time: 11.14, playing: true, page: nil))
        check(wait { cursorSeen?.time == 11.14 }, "la position de lecture est partagée (« Suivez-moi »)")

        // 4. coupure : chacun écrit pendant la panne, le client se reconnecte seul
        client.simulateDrop()
        _ = wait(3) { client.state != .connected }
        let during1 = hostStore.addAnnotation(versionID: version, x: 0.2, y: 0.2, time: 9, text: "écrit côté hôte pendant la coupure")
        let during2 = clientStore.addAnnotation(versionID: version, x: 0.7, y: 0.3, time: 9.5, text: "écrit côté client pendant la coupure")
        check(wait(15) { clientStore.annotations[during1.id] != nil && hostStore.annotations[during2.id] != nil },
              "après la reconnexion automatique, tout ce qui a été écrit pendant la coupure est fusionné des deux côtés")
        check(hostStore.annotations.count == clientStore.annotations.count && hostStore.messages.count == clientStore.messages.count,
              "les deux côtés ont exactement le même état (aucune perte, aucun doublon)")
        check(hostStore.journal.all().count == clientStore.journal.all().count, "les deux journaux contiennent les mêmes opérations (\(hostStore.journal.all().count))")

        // 5. modification concurrente : la plus récente gagne des deux côtés
        hostStore.setStatus(a.id, .resolved)
        check(wait { clientStore.annotations[a.id]?.status == .resolved }, "le statut « résolu » se synchronise")

        // 6. rejeu : le même lot reçu deux fois ne compte qu'une fois
        let before = hostStore.journal.all().count
        hostStore.receive(clientStore.journal.all())
        check(hostStore.journal.all().count == before, "une opération reçue deux fois n'est comptée qu'une fois")

        // 7. sécurité : un client avec une mauvaise clé est refusé et ne reçoit rien
        let intruderStore = ReviewStore(dir: tmp.appendingPathComponent("intruder"), authorName: "Intrus", keyService: "test")
        let bad = Invitation(code: inv.code, secret: Data(repeating: 7, count: 16), host: nil, port: nil)
        let intruder = SessionEngine(role: .client, store: intruderStore, invitation: bad)
        intruder.connect(host: "127.0.0.1", port: port)
        _ = wait(4) { intruder.state == .connected }
        check(intruder.state != .connected && intruderStore.annotations.isEmpty, "un client sans la bonne clé est refusé et ne reçoit aucune donnée")
        intruder.stop()

        // 8. journal chiffré au repos
        let raw = (try? Data(contentsOf: tmp.appendingPathComponent("host/journal.sqlite"))) ?? Data()
        check(raw.range(of: Data("Le titre est trop petit".utf8)) == nil, "le texte des annotations n'apparaît pas en clair dans le journal")

        // 9. invitation : le lien se relit à l'identique
        var shared = inv; shared.host = "192.168.1.10"; shared.port = 5005
        check(Invitation(link: shared.link) == shared, "le lien d'invitation se relit à l'identique")

        // 10. transfert d'un proxy de 5 Mo : coupure en plein envoi, reprise au bloc suivant, empreinte vérifiée
        let big = tmp.appendingPathComponent("proxy.bin")
        var bytes = [UInt8](repeating: 0, count: 5 * 1024 * 1024 + 123); _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        try? Data(bytes).write(to: big)
        let vid = UUID()
        let offer = FileOffer(versionID: vid, name: "proxy.bin", size: bytes.count, sha256: ProxyMaker.sha256(big) ?? "", chunkSize: SessionEngine.chunkSize)
        host.fileProvider = { $0 == vid ? big : nil }
        host.projectsProvider = { [ProjectInfo(id: UUID(), name: "Essai", client: "", kind: .video, versions: [VersionInfo(id: vid, number: 1, date: Date(), file: offer)])] }
        let cache = ClientCache(dir: tmp.appendingPathComponent("client"))
        var fromChunks: [Int] = [], done = false, dropped = false, duplicates = 0
        client.onProjects = { infos in
            guard let o = infos.first?.versions.first?.file else { return }
            let n = cache.nextChunk(for: o); fromChunks.append(n)
            client.request(FileRequest(versionID: o.versionID, fromChunk: n))
        }
        client.onChunk = { id, index, data in
            if !cache.write(chunk: index, data: data, for: offer) { duplicates += 1 }
            if index == 6, !dropped { dropped = true; client.simulateDrop() }
        }
        client.onFileDone = { _ in done = true }
        host.announceProjects()
        check(wait(25) { done }, "le proxy arrive en entier malgré une coupure en plein envoi")
        check(fromChunks.count >= 2 && (fromChunks.last ?? 0) > 0, "la reprise repart du bloc suivant, pas de zéro (demandes : \(fromChunks))")
        let final = cache.complete(offer)
        check(final != nil && (try? Data(contentsOf: final!)) == Data(bytes), "la copie du client est identique à l'original (empreinte et contenu)")
        check(cache.has(offer), "le cache reconnaît la copie complète")
        // un fichier altéré est refusé
        let badOffer = FileOffer(versionID: UUID(), name: "x", size: 10, sha256: "00", chunkSize: SessionEngine.chunkSize)
        cache.write(chunk: 0, data: Data(repeating: 1, count: 10), for: badOffer)
        check(cache.complete(badOffer) == nil, "une copie dont l'empreinte est fausse est jetée")
        // plafond du cache : la copie la plus ancienne part la première
        cache.evict(maxBytes: 1, keep: [])
        check(!cache.has(offer), "le plafond d'espace efface les copies anciennes")

        client.stop(); host.stop()
        _ = wait(1) { false }
        try? FileManager.default.removeItem(at: tmp)
        print(failures == 0 ? "TOUT PASSE" : "\(failures) ÉCHEC(S)")
        return failures == 0 ? 0 : 1
    }
}

extension SelfTest {
    /// `--selftest-relay hôte:port` : hôte et client passent tous deux par le relais (mode « relais seulement »), chiffré de bout en bout, avec coupure.
    static func runRelay(_ addr: String) -> Int32 {
        setenv("MFRAMES_NO_KEYCHAIN", "1", 1)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mframes-relay-\(UUID().uuidString)")
        let hs = ReviewStore(dir: tmp.appendingPathComponent("h"), authorName: "Stéphan", keyService: "test")
        let cs = ReviewStore(dir: tmp.appendingPathComponent("c"), authorName: "Marie", keyService: "test")
        let inv = Invitation.new()
        var cfg = NetworkConfig(); cfg.mode = .relayOnly; cfg.rendezvousURL = addr
        let host = SessionEngine(role: .host, store: hs, invitation: inv); host.config = cfg
        _ = try? host.startHosting(port: 0, bonjour: false)
        let client = SessionEngine(role: .client, store: cs, invitation: host.invitation); client.config = cfg
        print("Essai par le relais \(addr) — salle \(host.invitation.room)")
        check(host.invitation.relay != nil && host.invitation.host == nil, "l'invitation contient le relais, aucune adresse directe")
        _ = wait(1) { false }
        client.connect()
        check(wait(10) { client.state == .connected }, "le client se connecte par le relais")
        let v = UUID()
        let a = cs.addAnnotation(versionID: v, x: 0.5, y: 0.5, text: "par le relais")
        check(wait { hs.annotations[a.id] != nil }, "l'annotation traverse le relais")
        client.simulateDrop()
        let b = hs.addAnnotation(versionID: v, x: 0.1, y: 0.1, text: "pendant la coupure")
        check(wait(20) { cs.annotations[b.id] != nil }, "après une coupure, le client se reconnecte par le relais et récupère tout")
        // clé fausse : le relais relaie, mais rien ne se déchiffre
        let bad = Invitation(code: inv.code, secret: inv.secret, host: nil, port: nil, publicHost: nil, relay: host.invitation.relay)
        let intruderStore = ReviewStore(dir: tmp.appendingPathComponent("i"), authorName: "Intrus", keyService: "test")
        var wrong = bad; wrong.secret = Data(repeating: 9, count: 16)
        let intruder = SessionEngine(role: .client, store: intruderStore, invitation: wrong); intruder.config = cfg
        intruder.connect()
        _ = wait(4) { intruder.state == .connected }
        check(intruderStore.annotations.isEmpty, "un client qui ne connaît pas le secret n'obtient rien (salle différente)")
        intruder.stop(); client.stop(); host.stop()
        _ = wait(1) { false }
        try? FileManager.default.removeItem(at: tmp)
        print(failures == 0 ? "TOUT PASSE" : "\(failures) ÉCHEC(S)")
        return failures == 0 ? 0 : 1
    }

    /// `--selftest-net` : lecture seule — analyse des adresses, STUN, découverte de la box (UPnP). N'ouvre aucun port.
    static func runNet() -> Int32 {
        check(Relay.parse("monserveur.fr")?.port == 7766 && Relay.parse("tcp://a.b:9000")?.port == 9000 && Relay.parse("") == nil, "adresses de relais : hôte seul, avec port, vide")
        var ip: String?
        for s in NetworkConfig().stunServers { ip = Stun.publicAddress(server: s); if ip != nil { break } }
        check(ip != nil, "STUN : adresse publique obtenue (\(ip ?? "aucune"))")
        if let g = UPnP.discover() {
            let ext = UPnP.externalIP(g)
            check(ext != nil, "UPnP : box trouvée, adresse externe lue (\(ext ?? "?"))")
        } else { print("  --  UPnP : aucune box ne répond (normal si l'UPnP est désactivé sur la box)") }
        print(failures == 0 ? "TOUT PASSE" : "\(failures) ÉCHEC(S)")
        return failures == 0 ? 0 : 1
    }
}

extension SelfTest {
    /// Requête HTTP brute (pour tester aussi un en-tête Host étranger) ; renvoie la réponse complète.
    static func raw(port: UInt16, _ request: String) -> String {
        var out = ""; var done = false
        DispatchQueue.global().async {
            let fd = socket(AF_INET, SOCK_STREAM, 0); defer { close(fd) }
            var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian; a.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            if ok == 0 {
                _ = request.withCString { send(fd, $0, strlen($0), 0) }
                var buf = [UInt8](repeating: 0, count: 65536), all = Data()
                while true { let n = recv(fd, &buf, buf.count, 0); if n <= 0 { break }; all.append(contentsOf: buf[0 ..< n]) }
                out = String(decoding: all, as: UTF8.self)
            }
            done = true
        }
        _ = wait(8) { done }
        return out
    }

    /// `--selftest-bridge` : pont local — jeton, hôte étranger refusé, lecture, statut, nouvelle version, exports de marqueurs.
    @MainActor static func runBridge() -> Int32 {
        setenv("MFRAMES_NO_KEYCHAIN", "1", 1)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mframes-bridge-\(UUID().uuidString)")
        setenv("MFRAMES_DATA_DIR", tmp.path, 1)
        let port = UInt16(30000 + Int.random(in: 0 ..< 20000))
        setenv("MFRAMES_BRIDGE_PORT", String(port), 1)
        let model = AppModel.shared
        DemoData.load(into: model)
        model.bridgeEnabled = true
        _ = wait(3) { FileManager.default.fileExists(atPath: tmp.appendingPathComponent("bridge.json").path) }
        let token = model.bridge.token
        func get(_ path: String, auth: Bool = true, host: String = "127.0.0.1") -> String {
            raw(port: port, "GET \(path) HTTP/1.1\r\nHost: \(host)\r\n\(auth ? "Authorization: Bearer \(token)\r\n" : "")Connection: close\r\n\r\n")
        }
        func post(_ path: String, _ body: String) -> String {
            raw(port: port, "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)")
        }
        check(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("bridge.json").path), "bridge.json (port et jeton) est écrit pour les modules")
        check(get("/v1/status", auth: false).contains("401"), "sans jeton : refusé (401)")
        check(get("/v1/status", host: "evil.example.com").contains("403"), "hôte étranger (DNS rebinding) : refusé (403)")
        check(get("/v1/status").contains("\"api\":1"), "avec le jeton : état et version d'API")
        let projects = get("/v1/projects")
        check(projects.contains("Affiche A2") && projects.contains("Spot 30 s"), "liste des projets et versions")
        let vid = model.projects.first!.versions.last!.id
        let ann = get("/v1/annotations?versionID=\(vid.uuidString)")
        check(ann.contains("Le titre est trop petit") && ann.contains("\"replies\""), "annotations avec leurs réponses")
        let aid = model.store.annotations(for: vid).first { $0.text.hasPrefix("Le titre") }!.id
        check(post("/v1/annotations/\(aid.uuidString)/status", "{\"status\":\"resolved\"}").contains("\"ok\":true") && model.store.annotations[aid]?.status == .resolved, "marquer résolu depuis un logiciel se répercute dans l'appli")
        check(post("/v1/annotations/\(aid.uuidString)/replies", "{\"text\":\"Corrigé en V3\",\"author\":\"Agent test\"}").contains("\"ok\":true"), "un agent peut répondre à un retour")
        check(get("/v1/annotations?versionID=\(vid.uuidString)").contains("Corrigé en V3") && get("/v1/annotations?versionID=\(vid.uuidString)").contains("Agent test"), "la réponse porte le nom de l'agent")
        model.selectedVersionID = vid
        check(get("/v1/submissions").hasSuffix("[]"), "aucun envoi au départ")
        model.sendToAgent()
        check(get("/v1/submissions").contains("\"seq\":1") && get("/v1/submissions?since=1").hasSuffix("[]"), "« Envoyer à Claude » apparaît dans le pont, « depuis » filtre")
        let todel = model.store.annotations(for: vid).first!.id
        model.store.delete(annotation: todel)
        check(!model.store.annotations(for: vid).contains { $0.id == todel }, "supprimer une épingle")
        let since = get("/v1/annotations?versionID=\(vid.uuidString)&since=999999")
        check(since.hasSuffix("[]"), "« depuis » ne renvoie que les retours plus récents")
        let file = tmp.appendingPathComponent("v3.png"); try? Data(count: 10).write(to: file)
        let pid = model.projects.first!.id
        check(post("/v1/projects/\(pid.uuidString)/versions", "{\"path\":\"\(file.path)\"}").contains("\"number\":3"), "un logiciel peut déposer une nouvelle version")
        let doc = tmp.appendingPathComponent("doc.png"); try? Data(count: 10).write(to: doc)
        check(post("/v1/projects", "{\"path\":\"\(doc.path)\",\"name\":\"Document agent\",\"client\":\"Test\"}").contains("Document agent") && model.projects.contains { $0.name == "Document agent" && $0.client == "Test" }, "un agent peut publier un nouveau document")
        if let d = model.projects.first(where: { $0.name == "Document agent" }) { model.deleteProject(d.id) }
        check(!model.projects.contains { $0.name == "Document agent" } && FileManager.default.fileExists(atPath: doc.path), "supprimer un projet le retire de la liste sans effacer le fichier")
        // exports : formats bien formés
        func export(_ f: String) -> String { get("/v1/export?versionID=\(vid.uuidString)&format=\(f)&fps=25") }
        func body(_ r: String) -> String { r.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n") }
        func wellFormed(_ s: String) -> Bool { let p = XMLParser(data: Data(s.utf8)); return p.parse() }
        check(body(export("edl")).contains("|C:ResolveColor") && body(export("edl")).contains("00:00:00:00"), "EDL (Resolve) : marqueurs colorés")
        check(wellFormed(body(export("fcpxml"))) && body(export("fcpxml")).contains("<marker "), "FCPXML (Final Cut Pro) : XML valide avec marqueurs")
        check(wellFormed(body(export("premiere"))) && body(export("premiere")).contains("<marker>"), "XML Premiere : XML valide avec marqueurs")
        check(body(export("aejsx")).contains("markerProperty.setValueAtTime"), "script After Effects généré")
        check(body(export("csv")).hasPrefix("numero,timecode"), "CSV généré")
        model.bridgeEnabled = false
        _ = wait(1) { false }
        check(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent("bridge.json").path), "désactivé : bridge.json disparaît")
        try? FileManager.default.removeItem(at: tmp)
        print(failures == 0 ? "TOUT PASSE" : "\(failures) ÉCHEC(S)")
        return failures == 0 ? 0 : 1
    }
}

extension SelfTest {
    /// `--selftest-player <vidéo>` : lecteur — Espace, flèches image par image (événements clavier réels envoyés à l'appli).
    @MainActor static func runPlayer(_ path: String) -> Int32 {
        let pc = PlayerController(); pc.load(path: path)
        _ = wait(3) { pc.duration > 0 && pc.player.currentItem?.status == .readyToPlay }
        let keys = PlayerKeys(); keys.install(pc)
        func press(_ code: UInt16, shift: Bool = false) {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: code)!
            NSApp.sendEvent(e); _ = wait(0.4) { false }
        }
        check(pc.fps > 24 && pc.fps < 26, "cadence lue : \(pc.fps) i/s")
        check(pc.naturalSize.width == 1280 && pc.naturalSize.height == 720, "taille lue : \(pc.naturalSize)")
        press(124); check(abs(pc.time - 1 / pc.fps) < 0.002, "→ avance d'une image (t = \(pc.time))")
        press(124); check(abs(pc.time - 2 / pc.fps) < 0.002, "→ encore une image (t = \(pc.time))")
        press(123); check(abs(pc.time - 1 / pc.fps) < 0.002, "← recule d'une image (t = \(pc.time))")
        press(124, shift: true); check(abs(pc.time - 11 / pc.fps) < 0.002, "⇧→ avance de 10 images (t = \(pc.time))")
        press(49); _ = wait(0.5) { false }; check(pc.player.rate != 0, "Espace lance la lecture")
        press(49); check(pc.player.rate == 0, "Espace arrête la lecture")
        keys.remove()
        print(failures == 0 ? "TOUT PASSE" : "\(failures) ÉCHEC(S)")
        return failures == 0 ? 0 : 1
    }
}

extension SelfTest {
    /// `--web-demo [secondes]` : héberge une session de démonstration avec le serveur web et affiche l'adresse du client navigateur ; affiche aussi ce qu'il envoie (essais Playwright).
    @MainActor static func runWebDemo(seconds: Double) -> Int32 {
        setenv("MFRAMES_NO_KEYCHAIN", "1", 1)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mframes-web-\(UUID().uuidString)")
        setenv("MFRAMES_DATA_DIR", tmp.path, 1)
        let model = AppModel.shared
        DemoData.load(into: model)
        model.startHosting()
        _ = wait(5) { model.invitation?.webPort != nil && model.invitation?.port != nil && model.invitation?.host != nil }
        guard let inv = model.invitation, inv.webPort != nil else { print("ÉCHEC : pas de serveur web"); return 1 }
        print("APP_LINK=\(inv.link)")
        print("WEB_URL=\(inv.webLink(host: "127.0.0.1"))")
        var bad = Invitation(code: inv.code, secret: Data(repeating: 5, count: 16), host: nil, port: nil); bad.webPort = inv.webPort
        print("WEB_BAD_URL=\(bad.webLink(host: "127.0.0.1"))")
        fflush(stdout)
        var seen = Set<UUID>()
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            for a in model.store.annotations.values where a.author.id.hasPrefix("WEB-") && !seen.contains(a.id) { seen.insert(a.id); print("WEB_ANNOTATION kind=\(a.kind.rawValue) x=\(String(format: "%.2f", a.x)) time=\(a.time.map { String($0) } ?? "-")"); fflush(stdout) }
            for a in model.store.annotations.values where a.author.name == "Essai deux Mac" && !seen.contains(a.id) { seen.insert(a.id); print("CLIENT_ANNOTATION \(a.text)"); fflush(stdout) }
            for m in model.store.messages.values where m.author.id.hasPrefix("WEB-") && !seen.contains(m.id) { seen.insert(m.id); print("WEB_MESSAGE \(m.text)"); fflush(stdout) }
            if FileManager.default.fileExists(atPath: "/tmp/mframes-web-stop") { break }
        }
        model.stopSession()
        try? FileManager.default.removeItem(at: tmp)
        return 0
    }
}

extension SelfTest {
    /// `--bridge-demo [secondes]` : données de démonstration, pont local actif ; écrit bridge.json dans MFRAMES_DATA_DIR et attend (essais des modules des logiciels de montage).
    @MainActor static func runBridgeDemo(seconds: Double) -> Int32 {
        setenv("MFRAMES_NO_KEYCHAIN", "1", 1)
        let model = AppModel.shared
        DemoData.load(into: model)
        model.bridgeEnabled = true
        _ = wait(3) { model.bridge.port != 0 }
        print("BRIDGE_PORT=\(model.bridge.port)"); fflush(stdout)
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            if FileManager.default.fileExists(atPath: "/tmp/mframes-bridge-stop") { break }
        }
        return 0
    }
}

extension SelfTest {
    /// `--selftest-upnp` : ouvre un port TCP élevé sur la vraie box pendant quelques secondes, vérifie la redirection, puis la supprime. À lancer sur demande seulement.
    static func runUPnP() -> Int32 {
        guard let g = UPnP.discover() else { print("  --  aucune box UPnP"); return 1 }
        guard let local = Network.localAddress() else { print("  --  adresse locale introuvable"); return 1 }
        let port = UInt16(47_000 + Int.random(in: 0 ..< 1000))
        check(!UPnP.hasMapping(g, port: port), "le port \(port) n'est pas encore redirigé")
        check(UPnP.map(g, port: port, localIP: local, leaseSeconds: 120), "la box accepte la redirection du port \(port) vers \(local) (bail de 120 s)")
        check(UPnP.hasMapping(g, port: port), "la box confirme la redirection")
        // joignabilité depuis l'extérieur de la maison : impossible à vérifier d'ici ; essai « de l'intérieur » par l'adresse publique (dépend de la box)
        var hair = false
        if let ext = UPnP.externalIP(g) {
            let l = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            l?.newConnectionHandler = { $0.cancel() }; l?.start(queue: .main)
            _ = wait(1) { false }
            let c = NWConnection(host: NWEndpoint.Host(ext), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            var ok = false; c.stateUpdateHandler = { if case .ready = $0 { ok = true } }; c.start(queue: .main)
            _ = wait(4) { ok }; hair = ok; c.cancel(); l?.cancel()
        }
        print("  --  connexion à l'adresse publique depuis le réseau local : \(hair ? "réussie" : "non (boucle interne non gérée par la box, normal)")")
        UPnP.unmap(g, port: port)
        check(!UPnP.hasMapping(g, port: port), "la redirection est supprimée, la box est remise comme avant")
        print(failures == 0 ? "TOUT PASSE" : "\(failures) ÉCHEC(S)")
        return failures == 0 ? 0 : 1
    }
}

extension SelfTest {
    /// `--join-demo "<lien mframes://…>"` : rejoint une session `--web-demo` d'un autre processus ou d'un autre Mac, vérifie la réception (retours, copie du proxy), envoie une annotation.
    @MainActor static func runJoinDemo(link: String) -> Int32 {
        setenv("MFRAMES_NO_KEYCHAIN", "1", 1)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mframes-join-\(UUID().uuidString)")
        setenv("MFRAMES_DATA_DIR", tmp.path, 1)
        UserDefaults.standard.set("Essai deux Mac", forKey: "authorName")
        let model = AppModel.shared
        guard Invitation(link: link) != nil else { print("  ÉCHEC  lien invalide"); return 1 }
        model.join(link: link)
        check(wait(15) { model.sessionState == .connected }, "connexion à l'hôte")
        check(wait(20) { model.store.annotations.count >= 3 }, "les retours de l'hôte arrivent (\(model.store.annotations.count))")
        check(wait(30) { model.transfers.values.contains(1) }, "la copie locale du proxy est complète (empreinte vérifiée)")
        let vid = model.store.annotations.values.first?.versionID ?? UUID()
        model.store.addAnnotation(versionID: vid, x: 0.5, y: 0.5, text: "envoyé par le second poste")
        _ = wait(3) { false }
        print(failures == 0 ? "TOUT PASSE" : "\(failures) ÉCHEC(S)")
        model.stopSession(); try? FileManager.default.removeItem(at: tmp)
        return failures == 0 ? 0 : 1
    }
}
