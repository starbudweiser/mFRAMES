// mFRAMES — session en direct entre le prestataire (hôte) et le client, en pair-à-pair, chiffrée de bout en bout.
// Transport : Network.framework (TCP) sur le réseau local ou par adresse directe ; annonce Bonjour pour la découverte.
// Chiffrement : AES-GCM, clé dérivée (HKDF) du secret de l'invitation ; chaque message porte un compteur croissant (anti-rejeu).
// Coupure : le client se reconnecte seul (délais croissants) ; à chaque connexion, les deux côtés échangent ce qu'ils ont (`have`)
// et n'envoient que les opérations manquantes. Le prototype transporte aussi la position de lecture (« Suivez-moi »).
import Foundation
import Network
import CryptoKit

enum Wire: Codable {
    case hello(Hello)
    case ops([Op])
    case cursor(Cursor)
    case projects([ProjectInfo])       // hôte → client : ce qu'il peut voir (projets, versions, fichiers proposés)
    case fileRequest(FileRequest)      // client → hôte : « envoie-moi ce fichier à partir du bloc n » (reprise après coupure)
    case fileDone(UUID)                // hôte → client : tous les blocs sont envoyés
    case bye
}

/// Fichier proposé au client : le proxy léger (jamais l'original).
struct FileOffer: Codable, Equatable {
    var versionID: UUID
    var name: String
    var size: Int
    var sha256: String
    var chunkSize: Int
}
struct VersionInfo: Codable, Equatable { var id: UUID; var number: Int; var date: Date; var file: FileOffer? }
struct ProjectInfo: Codable, Equatable { var id: UUID; var name: String; var client: String; var kind: MediaKind; var versions: [VersionInfo] }
struct FileRequest: Codable { var versionID: UUID; var fromChunk: Int }

struct Hello: Codable {
    var peer: PeerInfo
    var have: [String: Int]
}


/// Invitation : code lisible (6 chiffres) + secret aléatoire (dans le lien) d'où vient la clé.
struct Invitation: Equatable {
    var code: String
    var secret: Data
    var host: String?
    var port: UInt16?
    var publicHost: String?     // adresse vue d'Internet (UPnP ou STUN) : permet la connexion directe hors du réseau local
    var relay: String?          // relais (hôte:port) : le client n'a rien à régler
    var webPort: UInt16?        // serveur web de l'hôte (client navigateur)

    /// Lien pour le navigateur : le secret reste dans le fragment (#…), que le navigateur n'envoie jamais au serveur.
    func webLink(host: String) -> String {
        let k = secret.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "http://\(host):\(webPort ?? 0)/#c=\(code)&k=\(k)"
    }

    /// Salle du relais : empreinte du secret (le relais ne voit jamais le secret).
    var room: String {
        let d = SHA256.hash(data: secret + Data("mFRAMES-room".utf8))
        return d.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func new() -> Invitation {
        let code = String(format: "%06d", Int.random(in: 0 ... 999_999))
        var s = Data(count: 16); _ = s.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return Invitation(code: code, secret: s, host: nil, port: nil)
    }
    var key: SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data("mFRAMES-session-v1".utf8), info: Data(code.utf8), outputByteCount: 32)
    }
    var link: String {
        var c = URLComponents(); c.scheme = "mframes"; c.host = "join"
        c.queryItems = [URLQueryItem(name: "c", value: code), URLQueryItem(name: "k", value: secret.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")),
                        URLQueryItem(name: "h", value: host), URLQueryItem(name: "p", value: port.map(String.init)), URLQueryItem(name: "ph", value: publicHost), URLQueryItem(name: "r", value: relay)].filter { $0.value != nil }
        return c.url?.absoluteString ?? ""
    }
    init(code: String, secret: Data, host: String?, port: UInt16?, publicHost: String? = nil, relay: String? = nil) { self.code = code; self.secret = secret; self.host = host; self.port = port; self.publicHost = publicHost; self.relay = relay }
    init?(link: String) {
        guard let c = URLComponents(string: link), c.scheme == "mframes", let items = c.queryItems else { return nil }
        func v(_ n: String) -> String? { items.first { $0.name == n }?.value }
        guard let code = v("c"), let k = v("k") else { return nil }
        var b = k.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let secret = Data(base64Encoded: b) else { return nil }
        self.init(code: code, secret: secret, host: v("h"), port: v("p").flatMap { UInt16($0) }, publicHost: v("ph"), relay: v("r"))
    }
}

/// Une liaison TCP chiffrée, avec messages encadrés : 4 octets de longueur + trame scellée (AES-GCM).
/// Trame en clair : type (1 octet : 0 message JSON, 1 bloc de fichier) + compteur (8 octets, anti-rejeu) + contenu.
final class SecureLink {
    let conn: NWConnection
    private let key: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var recvCounter: UInt64 = 0
    var onWire: ((Wire) -> Void)?
    var onChunk: ((UUID, Int, Data) -> Void)?
    var onClose: (() -> Void)?
    private(set) var closed = false
    private(set) var established = false

    init(_ conn: NWConnection, key: SymmetricKey) { self.conn = conn; self.key = key }

    /// Liaison par un relais : envoie la ligne d'accueil, attend la réponse attendue, puis la liaison est transparente.
    func startRelay(queue: DispatchQueue, preamble: String, expect: String, onReady: @escaping () -> Void) {
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.conn.send(content: Data(preamble.utf8), completion: .contentProcessed { e in if e != nil { self.close() } })
                self.readLine { line in
                    guard line == expect else { self.close(); return }
                    self.established = true; onReady(); self.receiveLength()
                }
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        conn.start(queue: queue)
    }
    private func readLine(_ done: @escaping (String?) -> Void, _ acc: [UInt8] = []) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] d, _, _, e in
            guard let self, let b = d?.first, e == nil, acc.count < 16 else { done(nil); return }
            if b == 10 { done(String(decoding: acc, as: UTF8.self) + "\n") } else { self.readLine(done, acc + [b]) }
        }
    }

    func start(queue: DispatchQueue, onReady: @escaping () -> Void) {
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: self?.established = true; onReady(); self?.receiveLength()
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        conn.start(queue: queue)
    }

    /// Mode navigateur : chaque trame scellée voyage dans un message WebSocket binaire (au lieu de 4 octets de longueur).
    private var wsParser: WSParser?
    var isWebSocket: Bool { wsParser != nil }

    private func frame(type: UInt8, _ body: Data) -> Data? {
        sendCounter += 1
        var plain = Data([type])
        var n = sendCounter.bigEndian
        plain.append(Data(bytes: &n, count: 8)); plain.append(body)
        guard let sealed = try? AES.GCM.seal(plain, using: key).combined else { return nil }
        if wsParser != nil { return WS.frame(sealed) }
        var len = UInt32(sealed.count).bigEndian
        var f = Data(bytes: &len, count: 4); f.append(sealed)
        return f
    }

    /// Reprend une connexion WebSocket déjà négociée (poignée de main HTTP faite par le serveur web) et lit les messages.
    func startWebSocket(leftover: Data, onReady: @escaping () -> Void) {
        wsParser = WSParser()
        established = true
        conn.stateUpdateHandler = { [weak self] st in if case .failed = st { self?.close() } else if case .cancelled = st { self?.close() } }
        onReady()
        if !leftover.isEmpty { feedWS(leftover) }
        receiveWS()
    }
    private func receiveWS() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { [weak self] d, _, done, e in
            guard let self, let d, e == nil else { self?.close(); return }
            self.feedWS(d)
            if !self.closed { self.receiveWS() }
        }
    }
    private func feedWS(_ d: Data) {
        guard wsParser != nil else { return }
        wsParser!.feed(d)
        while let m = wsParser!.next() {
            switch m {
            case .binary(let sealed): process(sealed)
            case .ping(let p): conn.send(content: WS.frame(p, opcode: 0xA), completion: .idempotent)
            case .close: close(); return
            case .invalid: close(); return
            }
            if closed { return }
        }
    }

    func send(_ wire: Wire) {
        guard let body = try? JSON.encoder.encode(wire), let f = frame(type: 0, body) else { return }
        conn.send(content: f, completion: .contentProcessed { [weak self] e in if e != nil { self?.close() } })
    }

    /// Bloc de fichier ; `done` est appelé quand il est parti (pour envoyer le suivant sans saturer la mémoire).
    func sendChunk(version: UUID, index: Int, data: Data, done: @escaping () -> Void) {
        var body = Data()
        var u = version.uuid; body = Data(bytes: &u, count: 16)
        var i = UInt32(index).bigEndian; body.append(Data(bytes: &i, count: 4)); body.append(data)
        guard let f = frame(type: 1, body) else { return }
        conn.send(content: f, completion: .contentProcessed { [weak self] e in if e != nil { self?.close() } else { done() } })
    }

    private func receiveLength() {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] d, _, _, e in
            guard let self, let d, d.count == 4, e == nil else { self?.close(); return }
            let n = Int(UInt32(bigEndian: d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            guard n > 28 + 9, n < 64 * 1024 * 1024 else { self.close(); return }   // taille raisonnable seulement
            self.receiveBody(n)
        }
    }
    private func receiveBody(_ n: Int) {
        conn.receive(minimumIncompleteLength: n, maximumLength: n) { [weak self] d, _, _, e in
            guard let self, let d, d.count == n, e == nil else { self?.close(); return }
            // une clé fausse ou un message modifié : la liaison est coupée, rien n'est lu
            self.process(d)
            if !self.closed { self.receiveLength() }
        }
    }

    /// Ouvre une trame scellée (clé fausse ou message modifié : la liaison est coupée, rien n'est lu) et la remet à l'écoute.
    private func process(_ sealed: Data) {
        guard let plain = try? AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key), plain.count >= 9 else { close(); return }
        let type = plain[plain.startIndex]
        let counter = plain[plain.startIndex + 1 ..< plain.startIndex + 9].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard counter == recvCounter + 1 else { close(); return }
        recvCounter = counter
        let body = plain.dropFirst(9)
        if type == 0 {
            guard let w = try? JSON.decoder.decode(Wire.self, from: body) else { close(); return }
            onWire?(w)
        } else if type == 1, body.count >= 20 {
            let b = Data(body)
            let id = b.prefix(16).withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
            let idx = Int(UInt32(bigEndian: b[16 ..< 20].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
            onChunk?(id, idx, b.dropFirst(20))
        } else { close() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        conn.cancel()
        onClose?()
    }
}

final class SessionEngine {
    enum Role { case host, client }
    enum State: Equatable { case idle, listening(UInt16), connecting, connected, reconnecting(Int), refused }

    let role: Role
    let store: ReviewStore
    var invitation: Invitation
    private let queue = DispatchQueue(label: "mframes.session")
    private var listener: NWListener?
    private var links: [SecureLink] = []
    private var stopped = false
    private var attempt = 0
    private var browser: NWBrowser?

    /// Rappels, toujours sur le fil principal.
    var onState: ((State) -> Void)?
    var onPeer: ((PeerInfo) -> Void)?
    var onPeerLeft: (() -> Void)?
    var onCursor: ((Cursor) -> Void)?
    var onProjects: (([ProjectInfo]) -> Void)?             // client : ce que l'hôte propose (fil principal)
    var onChunk: ((UUID, Int, Data) -> Void)?              // client : un bloc reçu (fil de la session)
    var onFileDone: ((UUID) -> Void)?                      // client : fichier complet (fil principal)
    var projectsProvider: (() -> [ProjectInfo])?           // hôte : projets à montrer
    var fileProvider: ((UUID) -> URL?)?                    // hôte : proxy d'une version
    static let chunkSize = 256 * 1024
    private(set) var state: State = .idle { didSet { let s = state; DispatchQueue.main.async { self.onState?(s) } } }

    init(role: Role, store: ReviewStore, invitation: Invitation) {
        self.role = role; self.store = store; self.invitation = invitation
        let previous = store.onLocalOp
        store.onLocalOp = { [weak self] op in previous?(op); self?.broadcast(.ops([op])) }
    }

    /// Réglages réseau : mode, relais, proxy (lus à chaque connexion).
    var config = NetworkConfig()
    enum Candidate: Equatable { case direct(String, UInt16), relay(String, UInt16) }
    private var candidates: [Candidate] = []
    private var candIndex = 0
    private var idleRelay: [SecureLink] = []

    private func makeParams() -> NWParameters {
        let p = NWParameters.tcp
        if let u = URL(string: config.proxy), let h = u.host, let port = u.port, let pp = NWEndpoint.Port(rawValue: UInt16(port)) {
            let ep = NWEndpoint.hostPort(host: NWEndpoint.Host(h), port: pp)
            let pc = (u.scheme ?? "").hasPrefix("socks") ? ProxyConfiguration(socksv5Proxy: ep) : ProxyConfiguration(httpCONNECTProxy: ep, tlsOptions: nil)
            let ctx = NWParameters.PrivacyContext(description: "mFRAMES"); ctx.proxyConfigurations = [pc]
            p.setPrivacyContext(ctx)
        }
        return p
    }

    private func wire(_ link: SecureLink) {
        link.onWire = { [weak self, weak link] w in if let link { self?.handle(w, from: link) } }
        link.onChunk = { [weak self] id, i, d in self?.onChunk?(id, i, d) }
    }

    // MARK: Hôte

    /// Écoute (port 0 : libre), s'annonce sur le réseau local et, si un relais est réglé, s'y inscrit. Renvoie l'écoute (nil en mode « relais seulement »).
    @discardableResult
    func startHosting(port: UInt16 = 0, bonjour: Bool = true) throws -> NWListener? {
        stopped = false
        var listenerOut: NWListener?
        if config.mode != .relayOnly {
            let l = try NWListener(using: NWParameters.tcp, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
            if bonjour { l.service = NWListener.Service(name: "mFRAMES-\(invitation.code)", type: "_mframes._tcp") }
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { [weak self, weak l] st in
                if case .ready = st, let p = l?.port?.rawValue { self?.invitation.port = p; self?.state = .listening(p) }
            }
            l.start(queue: queue)
            listener = l; listenerOut = l
        }
        if config.mode != .lanOnly, config.mode != .directOnly, let r = Relay.parse(config.rendezvousURL) {
            invitation.relay = "\(r.host):\(r.port)"
            for _ in 0 ..< 2 { openIdleRelay(r) }
            if config.mode == .relayOnly { state = .listening(0) }
        }
        return listenerOut
    }

    private func accept(_ c: NWConnection) {
        let link = SecureLink(c, key: invitation.key)
        wire(link)
        link.onClose = { [weak self, weak link] in
            guard let self, let link else { return }
            self.queue.async { self.links.removeAll { $0 === link }; DispatchQueue.main.async { self.onPeerLeft?() } }
        }
        links.append(link)
        link.start(queue: queue) { [weak self, weak link] in if let link { self?.sendHello(on: link) } }
    }

    /// L'hôte garde des liaisons « en attente » vers le relais ; quand un client arrive, le relais en réveille une (« GO ») et l'hôte en rouvre une autre.
    private func openIdleRelay(_ r: (host: String, port: UInt16)) {
        guard !stopped else { return }
        let c = NWConnection(host: NWEndpoint.Host(r.host), port: NWEndpoint.Port(rawValue: r.port)!, using: makeParams())
        let link = SecureLink(c, key: invitation.key)
        wire(link)
        idleRelay.append(link)
        link.onClose = { [weak self, weak link] in
            guard let self, let link else { return }
            self.queue.async {
                self.idleRelay.removeAll { $0 === link }
                let wasPaired = link.established && self.links.contains { $0 === link }
                self.links.removeAll { $0 === link }
                DispatchQueue.main.async { self.onPeerLeft?() }
                if !wasPaired, !link.established { self.queue.asyncAfter(deadline: .now() + 5) { self.openIdleRelay(r) } }   // relais injoignable : nouvelle tentative
            }
        }
        link.startRelay(queue: queue, preamble: "HOST \(invitation.room)\n", expect: "GO\n") { [weak self, weak link] in
            guard let self, let link else { return }
            self.queue.async { self.idleRelay.removeAll { $0 === link }; self.links.append(link); self.openIdleRelay(r) }
            self.sendHello(on: link)
        }
    }

    /// Hôte : un navigateur s'est connecté au serveur web (WebSocket) ; il parle le même protocole chiffré.
    func adopt(_ link: SecureLink, leftover: Data) {
        wire(link)
        link.onClose = { [weak self, weak link] in
            guard let self, let link else { return }
            self.queue.async { self.links.removeAll { $0 === link }; DispatchQueue.main.async { self.onPeerLeft?() } }
        }
        queue.async {
            self.links.append(link)
            link.startWebSocket(leftover: leftover) { [weak self, weak link] in if let link { self?.sendHello(on: link) } }
        }
    }

    // MARK: Client

    /// Se connecte comme le dit l'invitation et les réglages : adresse locale, adresse publique, puis relais ; chaque échec passe au candidat suivant.
    func connect() {
        var list: [Candidate] = []
        let inv = invitation
        if config.mode != .relayOnly {
            if let h = inv.host, let p = inv.port { list.append(.direct(h, p)) }
            if config.mode != .lanOnly, let h = inv.publicHost, let p = inv.port { list.append(.direct(h, p)) }
        }
        if config.mode != .lanOnly, config.mode != .directOnly, let r = Relay.parse(inv.relay ?? config.rendezvousURL) { list.append(.relay(r.host, r.port)) }
        connect(candidates: list)
    }

    func connect(host: String, port: UInt16) { connect(candidates: [.direct(host, port)]) }

    func connect(candidates list: [Candidate]) {
        stopped = false; candidates = list; candIndex = 0; attempt = 0
        queue.async { self.startAttempt() }
    }

    private func startAttempt() {
        guard !stopped, !candidates.isEmpty else { return }
        state = attempt == 0 ? .connecting : .reconnecting(attempt)
        let cand = candidates[candIndex % candidates.count]
        let host: String, port: UInt16
        switch cand { case .direct(let h, let p): (host, port) = (h, p); case .relay(let h, let p): (host, port) = (h, p) }
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: makeParams())
        let link = SecureLink(c, key: invitation.key)
        wire(link)
        link.onClose = { [weak self, weak link] in
            guard let self, let link else { return }
            self.queue.async {
                let was = self.links.contains { $0 === link }
                self.links.removeAll { $0 === link }
                if was { DispatchQueue.main.async { self.onPeerLeft?() } }
                if !link.established { self.candIndex += 1 }          // échec de ce chemin : on essaie le suivant
                self.scheduleReconnect()
            }
        }
        links.append(link)
        let ready: () -> Void = { [weak self, weak link] in self?.attempt = 0; if let link { self?.sendHello(on: link) } }
        switch cand {
        case .direct: link.start(queue: queue, onReady: ready)
        case .relay: link.startRelay(queue: queue, preamble: "JOIN \(invitation.room)\n", expect: "OK\n", onReady: ready)
        }
        // un chemin qui ne répond pas en 4 s est abandonné
        queue.asyncAfter(deadline: .now() + 4) { [weak link] in if let link, !link.established { link.close() } }
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        attempt += 1
        state = .reconnecting(attempt)
        let delay = candidates.count > 1 && attempt <= candidates.count ? 0.3 : min(Double(1 << min(attempt - 1, 4)), 15)   // chaque chemin d'abord, puis 1, 2, 4, 8, 15 s
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.startAttempt() }
    }

    // MARK: Échanges

    private func me() -> PeerInfo { PeerInfo(name: store.author.name, role: role == .host ? "host" : "client", authorID: store.author.id) }

    private func sendHello(on link: SecureLink) {
        let have = store.journal.have()
        link.send(.hello(Hello(peer: me(), have: have)))
    }

    private func handle(_ wire: Wire, from link: SecureLink) {
        switch wire {
        case .hello(let h):
            // l'autre dit ce qu'il a : on lui envoie le reste (rien si tout y est déjà)
            let missing = store.journal.ops(after: h.have)
            if !missing.isEmpty { link.send(.ops(missing)) }
            if role == .host, let infos = DispatchQueue.main.sync(execute: { self.projectsProvider?() }) { link.send(.projects(infos)) }
            attempt = 0
            DispatchQueue.main.async { self.state = .connected; self.onPeer?(h.peer) }
        case .ops(let ops):
            let fresh = DispatchQueue.main.sync { self.store.receive(ops) }
            // l'hôte relaie aux autres clients
            if role == .host, !fresh.isEmpty { for l in links where l !== link { l.send(.ops(fresh)) } }
        case .cursor(let c):
            DispatchQueue.main.async { self.onCursor?(c) }
            if role == .host { for l in links where l !== link { l.send(.cursor(c)) } }
        case .projects(let infos):
            DispatchQueue.main.async { self.onProjects?(infos) }
        case .fileRequest(let r):
            guard role == .host, let url = DispatchQueue.main.sync(execute: { self.fileProvider?(r.versionID) }) else { return }
            stream(url: url, version: r.versionID, from: r.fromChunk, on: link)
        case .fileDone(let id):
            DispatchQueue.main.async { self.onFileDone?(id) }
        case .bye:
            link.close()
        }
    }

    /// Envoie le fichier bloc par bloc, à partir du bloc demandé (reprise), un bloc à la fois pour ne pas saturer la mémoire.
    private func stream(url: URL, version: UUID, from: Int, on link: SecureLink) {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        func next(_ index: Int) {
            guard !link.closed else { try? fh.close(); return }
            try? fh.seek(toOffset: UInt64(index * Self.chunkSize))
            guard let d = try? fh.read(upToCount: Self.chunkSize), !d.isEmpty else { try? fh.close(); link.send(.fileDone(version)); return }
            link.sendChunk(version: version, index: index, data: d) { self.queue.async { next(index + 1) } }
        }
        queue.async { next(max(0, from)) }
    }

    /// Hôte : annonce à tous les clients les projets et fichiers à jour.
    func announceProjects() {
        guard role == .host else { return }
        let infos = projectsProvider?() ?? []
        broadcast(.projects(infos))
    }
    /// Client : demande un fichier (à partir du bloc `fromChunk`).
    func request(_ r: FileRequest) { broadcast(.fileRequest(r)) }

    func broadcast(_ wire: Wire) { queue.async { for l in self.links { l.send(wire) } } }
    func send(cursor: Cursor) { broadcast(.cursor(cursor)) }

    /// Essais : coupe la liaison comme une panne de réseau ; le client se reconnecte seul.
    func simulateDrop() { queue.async { for l in self.links { l.close() } } }

    func stop() {
        stopped = true
        queue.async {
            for l in self.links { l.send(.bye) }
            self.listener?.cancel(); self.browser?.cancel(); for l in self.idleRelay { l.close() }
            self.queue.asyncAfter(deadline: .now() + 0.1) { for l in self.links { l.close() }; self.links.removeAll() }
        }
        state = .idle
    }
}
