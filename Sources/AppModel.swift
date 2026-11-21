// mFRAMES — modèle de l'appli : projets, sélection, session en cours, apparence, lecteur partagé.
import AppKit
import AVFoundation
import PDFKit
import Combine
import UniformTypeIdentifiers

enum Appearance: String, CaseIterable { case clair, sombre, auto }

@MainActor
final class AppModel: ObservableObject, @preconcurrency BridgeBackend {
    static let isDev = (Bundle.main.bundleIdentifier ?? "").hasSuffix(".dev")
    static let appName = isDev ? "mFRAMES DEV" : "mFRAMES"
    static let shared = AppModel()

    let store: ReviewStore
    @Published var selectedProjectID: UUID?
    @Published var selectedVersionID: UUID?
    @Published var search = ""
    @Published var tool: AnnotationKind = .pin
    @Published var selectedAnnotation: UUID?
    @Published var showInvite = false
    @Published var showSettings = false
    @Published var network: NetworkConfig
    @Published var appearance: Appearance { didSet { UserDefaults.standard.set(appearance.rawValue, forKey: "appearance"); applyAppearance() } }
    // session
    @Published var session: SessionEngine?
    @Published var sessionState: SessionEngine.State = .idle
    @Published var peer: PeerInfo?
    @Published var invitation: Invitation?
    @Published var follow = true
    @Published var page = 0                              // page affichée (PDF)
    @Published var transfers: [UUID: Double] = [:]       // avancement de la copie locale du client (0…1)
    let player = PlayerController()
    /// Envois « à l'agent » : chaque clic sur « Envoyer » ajoute une entrée (numéro croissant) que l'agent lit par le pont.
    @Published var submissions: [BridgeSubmission] = []
    lazy var bridge: Bridge = { let b = Bridge(dir: store.dir); b.backend = self; return b }()
    @Published var bridgeEnabled = UserDefaults.standard.bool(forKey: "bridgeEnabled") { didSet { UserDefaults.standard.set(bridgeEnabled, forKey: "bridgeEnabled"); applyBridge() } }
    lazy var cache = ClientCache(dir: store.dir)
    private var offers = OfferBox()                       // fichiers proposés par l'hôte (lus depuis le fil de la session)
    private var hostProxies: [UUID: URL] = [:]            // hôte : proxys prêts
    private var hostOffers: [UUID: FileOffer] = [:]
    private var requested = Set<UUID>()
    private var web: WebServer?
    private var upnpMapping: (UPnP.Gateway, UInt16)?
    @Published var inviteWeb = true                       // la feuille d'invitation montre le lien navigateur (sinon le lien de l'app cliente)
    var cacheLimitGB: Int { get { let v = UserDefaults.standard.integer(forKey: "cacheLimitGB"); return v == 0 ? 2 : v } set { UserDefaults.standard.set(newValue, forKey: "cacheLimitGB") } }
    private var bag = Set<AnyCancellable>()

    var projects: [Project] { store.projects }
    var project: Project? { projects.first { $0.id == selectedProjectID } }
    var version: ProjectVersion? { project?.versions.first { $0.id == selectedVersionID } ?? project?.currentVersion }

    init() {
        let dir = ReviewStore.dataDir(name: AppModel.appName)
        let name = UserDefaults.standard.string(forKey: "authorName") ?? NSFullUserName()
        store = ReviewStore(dir: dir, authorName: name.isEmpty ? NSUserName() : name, keyService: Bundle.main.bundleIdentifier ?? "fr.stephan.mframes")
        network = NetworkConfig.load(dir: dir)
        appearance = Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .sombre
        store.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.objectWillChange.send() } }.store(in: &bag)
        player.onUserSeek = { [weak self] in self?.broadcastCursor() }
        selectedProjectID = store.projects.first?.id
        applyAppearance()
        loadSubmissions()
        if bridgeEnabled { applyBridge() }
    }

    /// Cadence du média (images par seconde) pour les timecodes exportés ; 25 par défaut.
    func frameRate() -> Double {
        guard let v = version, project?.kind == .video, !v.mediaPath.isEmpty else { return 25 }
        let r = AVURLAsset(url: URL(fileURLWithPath: v.mediaPath)).tracks(withMediaType: .video).first?.nominalFrameRate ?? 25
        return r > 1 ? Double(r) : 25
    }

    func applyBridge() { if bridgeEnabled { try? bridge.start(port: UInt16(ProcessInfo.processInfo.environment["MFRAMES_BRIDGE_PORT"] ?? "") ?? Bridge.defaultPort) } else { bridge.stop() } }

    // MARK: Pont local (BridgeBackend)

    func bridgeCurrent() -> BridgeCurrent? {
        guard let p = project, let v = version else { return nil }
        return BridgeCurrent(projectID: p.id, versionID: v.id, name: p.name, number: v.number)
    }
    func bridgeProjects() -> [BridgeProject] {
        projects.map { p in BridgeProject(id: p.id, name: p.name, client: p.client, kind: p.kind.rawValue, versions: p.versions.map { BridgeVersion(id: $0.id, number: $0.number, date: $0.date) }) }
    }
    func bridgeAnnotations(versionID: UUID?, since: Int) -> [BridgeAnnotation] {
        let versions = versionID.map { [$0] } ?? projects.flatMap { $0.versions.map(\.id) }
        return versions.flatMap { v in store.annotations(for: v).filter { $0.lamport > since } .map { a in
            BridgeAnnotation(id: a.id, versionID: a.versionID, type: a.kind.rawValue, time: a.time, page: a.page, x: a.x, y: a.y, w: a.w, h: a.h, text: a.text, status: a.status.rawValue, author: a.author.name, lamport: a.lamport,
                             replies: store.messages(for: v).filter { $0.annotationID == a.id }.map { BridgeReply(author: $0.author.name, text: $0.text) })
        } }
    }
    func bridgeSetStatus(annotationID: UUID, status: ReviewStatus) -> Bool {
        guard store.annotations[annotationID] != nil else { return false }
        store.setStatus(annotationID, status); return true
    }
    func bridgeAddVersion(projectID: UUID, path: String) -> BridgeVersion? {
        guard projects.contains(where: { $0.id == projectID }) else { return nil }
        selectedProjectID = projectID
        addVersion(url: URL(fileURLWithPath: path))
        guard let v = project?.currentVersion else { return nil }
        return BridgeVersion(id: v.id, number: v.number, date: v.date)
    }
    func loadSubmissions() {
        if let d = try? Data(contentsOf: store.dir.appendingPathComponent("submissions.json")), let a = try? JSON.decoder.decode([BridgeSubmission].self, from: d) { submissions = a }
    }
    /// Pousse les retours ouverts de la version affichée vers l'agent ; renvoie leur nombre.
    @discardableResult func sendToAgent() -> Int {
        guard let v = version else { return 0 }
        let n = store.annotations(for: v.id).filter { $0.status == .open }.count + store.messages(for: v.id).filter { $0.annotationID == nil && $0.author.id == store.author.id && $0.lamport > (lastSentLamport(v.id)) }.count
        let lamport = max(store.annotations(for: v.id).map(\.lamport).max() ?? 0, store.messages(for: v.id).map(\.lamport).max() ?? 0)
        submissions.append(BridgeSubmission(seq: (submissions.last?.seq ?? 0) + 1, versionID: v.id, projectName: project?.name ?? "", versionNumber: v.number, lamport: lamport, count: n, date: Date()))
        if let d = try? JSON.encoder.encode(submissions) { try? d.write(to: store.dir.appendingPathComponent("submissions.json"), options: .atomic) }
        return n
    }
    func lastSentLamport(_ v: UUID) -> Int { submissions.last { $0.versionID == v }?.lamport ?? 0 }
    func bridgeSubmissions(since: Int) -> [BridgeSubmission] { submissions.filter { $0.seq > since } }
    func bridgeReply(annotationID: UUID, text: String, author: String?) -> Bool {
        guard let a = store.annotations[annotationID] else { return false }
        let name = (author?.isEmpty == false ? author! : "Agent IA")
        store.addMessage(versionID: a.versionID, annotationID: a.id, text: text, as: Author(id: "agent:" + name, name: name, colorIndex: 5))
        return true
    }
    func bridgeAddProject(path: String, name: String?, client: String?) -> BridgeProject? {
        addProject(url: URL(fileURLWithPath: path))
        guard var p = project, let i = store.projects.firstIndex(of: p) else { return nil }
        if let name, !name.isEmpty { p.name = name }
        if let client { p.client = client }
        store.projects[i] = p; store.saveProjects()
        return bridgeProjects().first { $0.id == p.id }
    }
    func bridgeExport(versionID: UUID, format: String, fps: Double) -> (String, String)? {
        guard let p = projects.first(where: { $0.versions.contains { $0.id == versionID } }), let v = p.versions.first(where: { $0.id == versionID }) else { return nil }
        let rows = MarkerExport.rows(store: store, versionID: versionID)
        let title = "\(p.name) V\(v.number)"
        let duration = (rows.last?.time ?? 0) + 5
        switch format {
        case "edl": return (MarkerExport.edl(rows, fps: fps, title: title), "text/plain; charset=utf-8")
        case "fcpxml": return (MarkerExport.fcpxml(rows, fps: fps, title: title, duration: duration), "application/xml")
        case "premiere": return (MarkerExport.premiereXML(rows, fps: fps, title: title, duration: duration), "application/xml")
        case "aejsx": return (MarkerExport.afterEffectsScript(rows), "text/plain; charset=utf-8")
        case "csv": return (MarkerExport.csv(rows, fps: fps), "text/csv; charset=utf-8")
        default: return nil
        }
    }

    func applyAppearance() {
        switch appearance {
        case .clair: NSApp?.appearance = NSAppearance(named: .aqua)
        case .sombre: NSApp?.appearance = NSAppearance(named: .darkAqua)
        case .auto: NSApp?.appearance = nil
        }
    }

    // MARK: PDF et mises en page : une page à la fois, rendue en image (mêmes épingles et zones que les images)

    private var pdfCache: (path: String, doc: PDFDocument)?
    func isPDF(_ v: ProjectVersion) -> Bool { v.mediaPath.lowercased().hasSuffix(".pdf") }
    func pdfDoc(_ path: String) -> PDFDocument? {
        if let c = pdfCache, c.path == path { return c.doc }
        guard let d = PDFDocument(url: URL(fileURLWithPath: path)) else { return nil }
        pdfCache = (path, d); return d
    }
    var pageCount: Int { version.flatMap { isPDF($0) ? pdfDoc($0.mediaPath)?.pageCount : nil } ?? 1 }
    func pdfImage() -> NSImage? {
        guard let v = version, isPDF(v), let doc = pdfDoc(v.mediaPath), let pg = doc.page(at: min(page, doc.pageCount - 1)) else { return nil }
        let r = pg.bounds(for: .mediaBox); let w: CGFloat = 1800
        return pg.thumbnail(of: NSSize(width: w, height: w * r.height / max(r.width, 1)), for: .mediaBox)
    }
    func goToPage(_ p: Int) { page = max(0, min(pageCount - 1, p)); broadcastCursor() }

    func saveNetwork() { network.save(dir: store.dir) }

    // MARK: Projets

    func addProject(url: URL) {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let kind: MediaKind = type?.conforms(to: .movie) == true ? .video : type?.conforms(to: .image) == true ? .image : type?.conforms(to: .pdf) == true ? .pdf : .design
        let v = ProjectVersion(id: UUID(), number: 1, path: url.path, proxyPath: nil, date: Date())
        let p = Project(id: UUID(), name: url.deletingPathExtension().lastPathComponent, client: "", kind: kind, versions: [v], created: Date())
        store.projects.append(p); store.saveProjects()
        selectedProjectID = p.id; selectedVersionID = v.id
        if session != nil { prepareProxies() }
    }

    func updateProject(_ id: UUID, name: String? = nil, client: String? = nil) {
        guard let i = store.projects.firstIndex(where: { $0.id == id }) else { return }
        if let n = name?.trimmingCharacters(in: .whitespaces), !n.isEmpty { store.projects[i].name = n }
        if let c = client { store.projects[i].client = c.trimmingCharacters(in: .whitespaces) }
        store.saveProjects(); objectWillChange.send()
    }
    /// Retire un projet de la liste ; le fichier d'origine n'est jamais touché.
    func deleteProject(_ id: UUID) {
        store.projects.removeAll { $0.id == id }; store.saveProjects()
        if selectedProjectID == id { selectedProjectID = store.projects.first?.id; selectedVersionID = project?.currentVersion?.id }
        objectWillChange.send()
    }
    func deleteVersion(project pid: UUID, version vid: UUID) {
        guard let i = store.projects.firstIndex(where: { $0.id == pid }) else { return }
        if store.projects[i].versions.count <= 1 { deleteProject(pid); return }
        store.projects[i].versions.removeAll { $0.id == vid }; store.saveProjects()
        if selectedVersionID == vid { selectedVersionID = store.projects[i].currentVersion?.id }
        objectWillChange.send()
    }
    var clients: [String] { Array(Set(projects.map(\.client).filter { !$0.isEmpty })).sorted() }

    func addVersion(url: URL) {
        guard var p = project, let i = store.projects.firstIndex(of: p) else { return }
        p.versions.append(ProjectVersion(id: UUID(), number: (p.versions.map(\.number).max() ?? 0) + 1, path: url.path, proxyPath: nil, date: Date()))
        store.projects[i] = p; store.saveProjects(); selectedVersionID = p.versions.last?.id
        if session != nil { prepareProxies() }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image, .pdf, .item]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let u = panel.url { addProject(url: u) }
    }

    // MARK: Session

    func startHosting() {
        stopSession()
        var inv = Invitation.new()
        let engine = SessionEngine(role: .host, store: store, invitation: inv)
        engine.config = network
        wire(engine)
        prepareProxies()
        do {
            try engine.startHosting(port: network.listenPort, bonjour: network.bonjour)
        } catch { return }
        if network.webClient && network.mode != .relayOnly {
            let w = WebServer(engine: engine, root: WebServer.defaultRoot())
            w.onReady = { [weak self, weak engine] p in DispatchQueue.main.async {
                guard let self, let engine else { return }
                engine.invitation.webPort = p; if var i = self.invitation { i.webPort = p; self.invitation = i }
            } }
            try? w.start(); web = w
        }
        inv.host = Network.localAddress(); inv.relay = engine.invitation.relay; inv.webPort = engine.invitation.webPort
        session = engine; invitation = inv
        discoverPublicAddress(engine)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self, weak engine] in   // le port est connu après l'ouverture de l'écoute
            guard let self, let engine else { return }
            var i = engine.invitation; i.host = Network.localAddress(); i.publicHost = self.invitation?.publicHost; i.webPort = engine.invitation.webPort; self.invitation = i
        }
    }

    /// Adresse vue d'Internet (UPnP, sinon STUN) : permet au client de se connecter directement hors du réseau local. Sans effet en mode « réseau local » ou « relais seulement ».
    private func discoverPublicAddress(_ engine: SessionEngine) {
        guard network.mode == .auto || network.mode == .directOnly else { return }
        let cfg = network
        Task.detached(priority: .utility) {
            var ip: String?
            if cfg.useUPnP, let g = UPnP.discover() {
                ip = UPnP.externalIP(g)
                if let port = engine.invitation.port, let local = Network.localAddress(), ip != nil, UPnP.map(g, port: port, localIP: local, leaseSeconds: 3600) {
                    await MainActor.run { self.upnpMapping = (g, port) }    // supprimée à la fin de la session
                }
            }
            if ip == nil { for s in cfg.stunServers { if let a = Stun.publicAddress(server: s) { ip = a; break } } }
            guard let ip else { return }
            await MainActor.run {
                engine.invitation.publicHost = ip
                if var i = self.invitation { i.publicHost = ip; self.invitation = i }
            }
        }
    }

    func join(link: String) {
        guard let inv = Invitation(link: link), (inv.host != nil && inv.port != nil) || inv.relay != nil || Relay.parse(network.rendezvousURL) != nil else { return }
        stopSession()
        let engine = SessionEngine(role: .client, store: store, invitation: inv)
        engine.config = network
        wire(engine)
        engine.connect()
        session = engine; invitation = inv
    }

    private func wire(_ e: SessionEngine) {
        e.onState = { [weak self] s in self?.sessionState = s }
        e.onPeer = { [weak self] p in self?.peer = p; self?.ensureRemoteProject() }
        e.onPeerLeft = { [weak self] in self?.peer = nil; self?.requested.removeAll() }
        e.projectsProvider = { [weak self] in self?.projectInfos() ?? [] }
        e.fileProvider = { [weak self] id in self?.hostProxies[id] }
        e.onProjects = { [weak self] infos in self?.receive(projects: infos) }
        e.onChunk = { [weak self] id, index, data in self?.receive(chunk: index, data: data, version: id) }
        e.onFileDone = { [weak self] id in self?.finishFile(id) }
        e.onCursor = { [weak self] c in guard let self, self.follow else { return }; if let pg = c.page, pg != self.page { self.page = pg }; self.player.apply(cursor: c) }
        player.onPlayState = { [weak self] in self?.broadcastCursor() }
    }

    // MARK: Transfert des médias (proxys)

    /// Hôte : fabrique les proxys manquants (en arrière-plan) puis les annonce aux clients.
    func prepareProxies() {
        for p in projects { for v in p.versions where !v.path.isEmpty && hostOffers[v.id] == nil {
            let project = p, version = v, store = self.store
            Task.detached(priority: .utility) {
                guard let url = await ProxyMaker.make(project: project, version: version, store: store), let offer = ProxyMaker.offer(for: url, versionID: version.id) else { return }
                await MainActor.run { self.hostProxies[version.id] = url; self.hostOffers[version.id] = offer; self.session?.announceProjects() }
            }
        } }
    }

    func projectInfos() -> [ProjectInfo] {
        projects.filter { $0.versions.contains { !$0.path.isEmpty } }.map { p in
            ProjectInfo(id: p.id, name: p.name, client: p.client, kind: p.kind, versions: p.versions.map { VersionInfo(id: $0.id, number: $0.number, date: $0.date, file: hostOffers[$0.id]) })
        }
    }

    /// Client : l'hôte propose des projets ; on crée ou met à jour leur copie et on demande les fichiers (en reprenant là où on s'était arrêté).
    func receive(projects infos: [ProjectInfo]) {
        for info in infos {
            var versions: [ProjectVersion] = []
            for v in info.versions {
                var local = ProjectVersion(id: v.id, number: v.number, path: "", proxyPath: nil, date: v.date)
                if let offer = v.file {
                    offers.set(offer)
                    if cache.has(offer) { local.proxyPath = cache.final(offer).path; transfers[v.id] = 1 }
                    else {
                        transfers[v.id] = Double(cache.bytesHave(offer)) / Double(max(offer.size, 1))
                        if !requested.contains(v.id) { requested.insert(v.id); session?.request(FileRequest(versionID: v.id, fromChunk: cache.nextChunk(for: offer))) }
                    }
                }
                versions.append(local)
            }
            if let i = store.projects.firstIndex(where: { $0.id == info.id }) {
                var p = store.projects[i]
                p.name = info.name; p.client = info.client; p.kind = info.kind
                for v in versions { if let j = p.versions.firstIndex(where: { $0.id == v.id }) { var m = p.versions[j]; m.proxyPath = v.proxyPath ?? m.proxyPath; p.versions[j] = m } else { p.versions.append(v) } }
                store.projects[i] = p
            } else {
                store.projects.append(Project(id: info.id, name: info.name, client: info.client, kind: info.kind, versions: versions, created: Date()))
            }
        }
        // les projets provisoires créés d'après les seuls retours sont remplacés par les vrais
        let real = Set(store.projects.flatMap { $0.versions.map(\.id) })
        store.projects.removeAll { p in p.name.hasPrefix("Session") && p.versions.count == 1 && infos.contains { $0.versions.contains { $0.id == p.versions[0].id } } && !infos.contains { $0.id == p.id } && real.contains(p.versions[0].id) && store.projects.filter { $0.versions.contains { $0.id == p.versions[0].id } }.count > 1 }
        store.saveProjects()
        if selectedProjectID == nil || project == nil { selectedProjectID = store.projects.first?.id }
        if selectedVersionID == nil || version == nil { selectedVersionID = project?.currentVersion?.id }
    }

    /// Un bloc reçu (fil de la session) : écrit dans le cache, avancement mis à jour sur le fil principal.
    func receive(chunk index: Int, data: Data, version id: UUID) {
        guard let offer = offers.get(id) else { return }
        cache.write(chunk: index, data: data, for: offer)
        let f = Double(cache.bytesHave(offer)) / Double(max(offer.size, 1))
        DispatchQueue.main.async { self.transfers[id] = f }
    }

    func finishFile(_ id: UUID) {
        guard let offer = offers.get(id) else { return }
        guard let url = cache.complete(offer) else {      // empreinte fausse : on jette et on repart de zéro
            transfers[id] = 0; session?.request(FileRequest(versionID: id, fromChunk: 0)); return
        }
        transfers[id] = 1
        for i in store.projects.indices { for j in store.projects[i].versions.indices where store.projects[i].versions[j].id == id { store.projects[i].versions[j].proxyPath = url.path } }
        store.saveProjects()
        if version?.id == id, project?.kind == .video { player.load(path: url.path) }
        objectWillChange.send()
        cache.evict(maxBytes: cacheLimitGB * 1_000_000_000, keep: Set(store.projects.flatMap { $0.versions.map(\.id) }.filter { transfers[$0] != nil }.prefix(8)))
    }

    func clearLocalCopy() { cache.clear(); transfers.removeAll(); for i in store.projects.indices { for j in store.projects[i].versions.indices where store.projects[i].versions[j].path.isEmpty { store.projects[i].versions[j].proxyPath = nil } }; store.saveProjects(); objectWillChange.send() }

    func stopSession() { if let (g, p) = upnpMapping { upnpMapping = nil; DispatchQueue.global().async { UPnP.unmap(g, port: p) } }; web?.stop(); web = nil; session?.stop(); session = nil; sessionState = .idle; peer = nil; invitation = nil }

    func broadcastCursor() {
        guard let s = session, case .connected = sessionState else { return }
        s.send(cursor: Cursor(versionID: version?.id, time: player.time, playing: player.playing, page: page))
    }

    /// Un client qui reçoit des retours d'une version qu'il ne connaît pas crée un projet vide en attente du média (le transfert des proxys vient ensuite).
    private func ensureRemoteProject() {
        let known = Set(projects.flatMap { $0.versions.map(\.id) })
        for vid in Set(store.annotations.values.map(\.versionID)) where !known.contains(vid) {
            let v = ProjectVersion(id: vid, number: 1, path: "", proxyPath: nil, date: Date())
            let p = Project(id: UUID(), name: peer.map { L.t("session.projectName", $0.name) } ?? L.t("session.projectDefault"), client: peer?.name ?? "", kind: .video, versions: [v], created: Date())
            store.projects.append(p); store.saveProjects()
            selectedProjectID = p.id; selectedVersionID = vid
        }
    }
}

/// Fichiers proposés, lisibles depuis plusieurs fils.
final class OfferBox {
    private var d: [UUID: FileOffer] = [:]
    private let lock = NSLock()
    func set(_ o: FileOffer) { lock.lock(); d[o.versionID] = o; lock.unlock() }
    func get(_ id: UUID) -> FileOffer? { lock.lock(); defer { lock.unlock() }; return d[id] }
}

enum Network {
    /// Première adresse IPv4 privée de ce Mac (pour le lien d'invitation sur le réseau local).
    static func localAddress() -> String? {
        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0, let first = ifa else { return nil }
        defer { freeifaddrs(ifa) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let a = p.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET), p.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0, p.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let s = String(cString: host)
            if s.hasPrefix("192.168.") || s.hasPrefix("10.") || s.hasPrefix("172.") { return s }
        }
        return nil
    }
}

/// Lecteur partagé : lecture, position, saut ; prévient quand l'utilisateur agit (pour « Suivez-moi »).
@MainActor
final class PlayerController: ObservableObject {
    let player = AVPlayer()
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
    var fps: Double = 25
    @Published var speed: Double = 1
    @Published var naturalSize: CGSize = .zero   // taille de l'image de la vidéo (rotation comprise)
    @Published var loop = false
    @Published var muted = false { didSet { player.isMuted = muted } }
    var markers: [Double] = []   // instants des annotations (secondes), pour ⏮ ⏭
    private var endObserver: Any?
    var onUserSeek: (() -> Void)?
    var onPlayState: (() -> Void)?
    private var observer: Any?
    private var applyingRemote = false

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; if self.loop { self.seek(0, user: false); self.player.playImmediately(atRate: Float(self.speed)) } else { self.playing = false } }
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return }
                let nt = t.seconds.isFinite ? t.seconds : 0
                if nt != self.time { self.time = nt }
                let np = self.player.rate != 0
                if np != self.playing { self.playing = np }
            }
        }
    }

    func load(path: String) {
        naturalSize = .zero
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { player.replaceCurrentItem(with: nil); duration = 0; time = 0; return }
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        player.replaceCurrentItem(with: item)
        item.preferredForwardBufferDuration = 4
        Task {
            let d = try? await item.asset.load(.duration); self.duration = d?.seconds ?? 0
            if let tr = try? await item.asset.loadTracks(withMediaType: .video).first {
                if let r = try? await tr.load(.nominalFrameRate), r > 1 { self.fps = Double(r) }
                if let sz = try? await tr.load(.naturalSize), let tf = try? await tr.load(.preferredTransform) {
                    let r = CGRect(origin: .zero, size: sz).applying(tf); self.naturalSize = CGSize(width: abs(r.width), height: abs(r.height))
                }
            }
        }
    }

    func toggle() {
        if player.rate == 0 { player.playImmediately(atRate: Float(speed)) } else { player.pause() }
        playing = player.rate != 0
        if !applyingRemote { onPlayState?() }
    }
    func seek(_ t: Double, user: Bool = true, exact: Bool = true) {
        let tol = exact ? CMTime.zero : CMTime(seconds: 0.3, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol)
        time = t
        if user, !applyingRemote { onUserSeek?() }
    }
    func frame(of t: Double) -> Int { Int((t * fps).rounded()) }
    func setSpeed(_ v: Double) { speed = v; if player.rate != 0 { player.rate = Float(v) } }
    func jump(toMarker next: Bool) {
        let t = time, e = 0.5 / fps
        let target = next ? markers.filter { $0 > t + e }.min() : markers.filter { $0 < t - e }.max()
        if let target { seek(target) }
    }
    func step(frames: Int) {
        player.pause(); playing = false
        let cur = player.currentTime().seconds.isFinite ? player.currentTime().seconds : time
        let target = max(0, min(duration > 0 ? duration : .infinity, ((cur * fps).rounded() + Double(frames)) / fps))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 6000), toleranceBefore: .zero, toleranceAfter: .zero)
        time = target
        if !applyingRemote { onUserSeek?() }
    }

    func apply(cursor c: Cursor) {
        applyingRemote = true; defer { applyingRemote = false }
        if abs(time - c.time) > 0.25 { seek(c.time, user: false) }
        if c.playing, player.rate == 0 { player.play() } else if !c.playing, player.rate != 0 { player.pause() }
    }
}
