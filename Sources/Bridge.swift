// mFRAMES — pont local pour les modules d'intégration (DaVinci Resolve, Premiere Pro, After Effects, Final Cut Pro) et les scripts.
// API JSON versionnée (/v1) sur 127.0.0.1 uniquement, protégée par un jeton, désactivée par défaut. Aucune en-tête CORS : une page web ne peut pas l'appeler.
import Foundation
import Network

struct BridgeAnnotation: Codable {
    var id: UUID; var versionID: UUID; var type: String; var time: Double?; var page: Int?
    var x: Double; var y: Double; var w: Double; var h: Double
    var text: String; var status: String; var author: String; var lamport: Int
    var replies: [BridgeReply]
}
struct BridgeReply: Codable { var author: String; var text: String }
struct BridgeVersion: Codable { var id: UUID; var number: Int; var date: Date }
struct BridgeCurrent: Codable { var projectID: UUID; var versionID: UUID; var name: String; var number: Int }
struct BridgeSubmission: Codable { var seq: Int; var versionID: UUID; var projectName: String; var versionNumber: Int; var lamport: Int; var count: Int; var date: Date }
struct BridgeProject: Codable { var id: UUID; var name: String; var client: String; var kind: String; var versions: [BridgeVersion] }

/// Ce que le pont lit et modifie ; implémenté par l'appli (sur le fil principal).
protocol BridgeBackend: AnyObject {
    func bridgeCurrent() -> BridgeCurrent?          // le projet et la version ouverts dans mFRAMES
    func bridgeProjects() -> [BridgeProject]
    func bridgeAnnotations(versionID: UUID?, since: Int) -> [BridgeAnnotation]
    func bridgeSetStatus(annotationID: UUID, status: ReviewStatus) -> Bool
    func bridgeAddVersion(projectID: UUID, path: String) -> BridgeVersion?
    func bridgeReply(annotationID: UUID, text: String, author: String?) -> Bool
    func bridgeSubmissions(since: Int) -> [BridgeSubmission]
    func bridgeAddProject(path: String, name: String?, client: String?) -> BridgeProject?
    func bridgeExport(versionID: UUID, format: String, fps: Double) -> (String, String)?   // (contenu, type MIME)
}

final class Bridge {
    static let apiVersion = 1
    static let defaultPort: UInt16 = 47_123
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "mframes.bridge")
    private(set) var token: String
    private(set) var port: UInt16 = 0
    weak var backend: BridgeBackend?
    let dir: URL

    init(dir: URL) {
        self.dir = dir
        let f = dir.appendingPathComponent("bridge.token")
        if let t = try? String(contentsOf: f, encoding: .utf8), t.count >= 32 { token = t.trimmingCharacters(in: .whitespacesAndNewlines) }
        else {
            var b = [UInt8](repeating: 0, count: 24); _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
            token = b.map { String(format: "%02x", $0) }.joined()
            try? token.write(to: f, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)
        }
    }

    /// Démarre l'écoute sur 127.0.0.1 et écrit `bridge.json` (port et jeton) que les modules lisent.
    func start(port wanted: UInt16 = Bridge.defaultPort) throws {
        stop()
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: wanted) ?? .any)
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard let self, case .ready = st, let p = l?.port?.rawValue else { return }
            self.port = p
            let info = "{\"api\":\(Bridge.apiVersion),\"port\":\(p),\"token\":\"\(self.token)\"}"
            let f = self.dir.appendingPathComponent("bridge.json")
            try? info.write(to: f, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)
        }
        l.start(queue: queue); listener = l
    }

    func stop() {
        listener?.cancel(); listener = nil
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("bridge.json"))
    }

    // MARK: HTTP minimal

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }
    private func read(_ c: NWConnection, _ acc: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, done, e in
            guard let self else { return }
            var buf = acc; if let d { buf.append(d) }
            if buf.count > 2_000_000 || e != nil { c.cancel(); return }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<r.lowerBound], as: UTF8.self)
                let len = head.lowercased().components(separatedBy: "\r\n").first { $0.hasPrefix("content-length:") }.flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                if buf.count - r.upperBound >= len { self.respond(c, head: head, body: buf[r.upperBound...].prefix(len)); return }
            }
            if done { c.cancel() } else { self.read(c, buf) }
        }
    }

    private func send(_ c: NWConnection, _ status: Int, _ body: Data, mime: String = "application/json; charset=utf-8") {
        let text = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "Error"
        var out = Data("HTTP/1.1 \(status) \(text)\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }
    private func json<T: Encodable>(_ c: NWConnection, _ v: T, status: Int = 200) { send(c, status, (try? JSON.encoder.encode(v)) ?? Data("{}".utf8)) }
    private func error(_ c: NWConnection, _ status: Int, _ msg: String) { send(c, status, Data("{\"error\":\"\(msg)\"}".utf8)) }

    private func respond(_ c: NWConnection, head: String, body: Data) {
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ").map(String.init)
        guard first.count >= 2 else { return error(c, 400, "requête invalide") }
        func header(_ n: String) -> String? { lines.dropFirst().first { $0.lowercased().hasPrefix(n.lowercased() + ":") }.map { String($0.dropFirst(n.count + 1)).trimmingCharacters(in: .whitespaces) } }
        // contre les pages web (DNS rebinding) : seul un hôte local est accepté
        let host = (header("Host") ?? "").split(separator: ":").first.map(String.init) ?? ""
        guard ["127.0.0.1", "localhost", "[::1]"].contains(host) else { return error(c, 403, "hôte refusé") }
        guard header("Authorization") == "Bearer \(token)" else { return error(c, 401, "jeton manquant ou faux") }
        let comps = URLComponents(string: "http://x" + first[1])
        let path = comps?.path ?? first[1]
        let q = Dictionary(uniqueKeysWithValues: (comps?.queryItems ?? []).compactMap { i in i.value.map { (i.name, $0) } })
        let method = first[0]

        switch (method, path) {
        case ("GET", "/v1/status"):
            let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            return send(c, 200, Data("{\"app\":\"mFRAMES\",\"version\":\"\(v)\",\"api\":\(Bridge.apiVersion)}".utf8))
        case ("GET", "/v1/current"):
            guard let cur = DispatchQueue.main.sync(execute: { self.backend?.bridgeCurrent() }) else { return error(c, 404, "aucun projet ouvert") }
            return json(c, cur)
        case ("GET", "/v1/projects"):
            let r = DispatchQueue.main.sync { self.backend?.bridgeProjects() ?? [] }
            return json(c, r)
        case ("GET", "/v1/annotations"):
            let r = DispatchQueue.main.sync { self.backend?.bridgeAnnotations(versionID: q["versionID"].flatMap(UUID.init), since: Int(q["since"] ?? "0") ?? 0) ?? [] }
            return json(c, r)
        case ("GET", "/v1/submissions"):
            return json(c, DispatchQueue.main.sync { self.backend?.bridgeSubmissions(since: Int(q["since"] ?? "0") ?? 0) ?? [] })
        case ("GET", "/v1/export"):
            guard let vid = q["versionID"].flatMap(UUID.init), let fmt = q["format"] else { return error(c, 400, "versionID et format requis") }
            guard let (content, mime) = DispatchQueue.main.sync(execute: { self.backend?.bridgeExport(versionID: vid, format: fmt, fps: Double(q["fps"] ?? "25") ?? 25) }) else { return error(c, 404, "format inconnu ou version introuvable") }
            return send(c, 200, Data(content.utf8), mime: mime)
        case ("POST", let p) where p.hasPrefix("/v1/annotations/") && p.hasSuffix("/status"):
            let id = p.dropFirst("/v1/annotations/".count).dropLast("/status".count)
            guard let uid = UUID(uuidString: String(id)), let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let s = (o["status"] as? String).flatMap(ReviewStatus.init) else { return error(c, 400, "identifiant ou statut invalide") }
            return DispatchQueue.main.sync { self.backend?.bridgeSetStatus(annotationID: uid, status: s) == true } ? send(c, 200, Data("{\"ok\":true}".utf8)) : error(c, 404, "annotation inconnue")
        case ("POST", let p) where p.hasPrefix("/v1/projects/") && p.hasSuffix("/versions"):
            let id = p.dropFirst("/v1/projects/".count).dropLast("/versions".count)
            guard let uid = UUID(uuidString: String(id)), let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let path = o["path"] as? String, FileManager.default.fileExists(atPath: path) else { return error(c, 400, "projet ou fichier invalide") }
            guard let v = DispatchQueue.main.sync(execute: { self.backend?.bridgeAddVersion(projectID: uid, path: path) }) else { return error(c, 404, "projet inconnu") }
            return json(c, v)
        case ("POST", let p) where p.hasPrefix("/v1/annotations/") && p.hasSuffix("/replies"):
            let id = p.dropFirst("/v1/annotations/".count).dropLast("/replies".count)
            guard let uid = UUID(uuidString: String(id)), let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let t = o["text"] as? String, !t.isEmpty else { return error(c, 400, "identifiant ou texte invalide") }
            return DispatchQueue.main.sync { self.backend?.bridgeReply(annotationID: uid, text: t, author: o["author"] as? String) == true } ? send(c, 200, Data("{\"ok\":true}".utf8)) : error(c, 404, "annotation inconnue")
        case ("POST", "/v1/projects"):
            guard let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let path = o["path"] as? String, FileManager.default.fileExists(atPath: path) else { return error(c, 400, "fichier invalide") }
            guard let r = DispatchQueue.main.sync(execute: { self.backend?.bridgeAddProject(path: path, name: o["name"] as? String, client: o["client"] as? String) }) else { return error(c, 400, "création impossible") }
            return json(c, r)
        default:
            return error(c, 404, "inconnu")
        }
    }
}
