import AppKit

// `mFRAMES --check-l10n` : vérifie que chaque texte existe dans les quatre langues (utilisé par tests/check_l10n.sh).
if CommandLine.arguments.contains("--check-l10n") {
    let problems = L.problems()
    if problems.isEmpty { print("OK : \(L.table.count) textes × 4 langues"); exit(0) }
    print("Textes incomplets : \(problems.joined(separator: ", "))"); exit(1)
}
// `mFRAMES --selftest` : session chiffrée, coupure et reprise, clé fausse (sans fenêtre).
if CommandLine.arguments.contains("--selftest") { exit(SelfTest.run()) }
if let i = CommandLine.arguments.firstIndex(of: "--selftest-relay"), CommandLine.arguments.indices.contains(i + 1) { exit(SelfTest.runRelay(CommandLine.arguments[i + 1])) }
if CommandLine.arguments.contains("--selftest-bridge") { exit(MainActor.assumeIsolated { SelfTest.runBridge() }) }
if let i = CommandLine.arguments.firstIndex(of: "--selftest-player"), i + 1 < CommandLine.arguments.count { _ = NSApplication.shared; exit(MainActor.assumeIsolated { SelfTest.runPlayer(CommandLine.arguments[i + 1]) }) }
if CommandLine.arguments.contains("--dump-wire") {
    let me = Author(id: "A1", name: "Marie", colorIndex: 2)
    let ann = Annotation(id: UUID(), versionID: UUID(), author: me, kind: .pin, x: 0.5, y: 0.5, w: 0, h: 0, time: 1.5, page: nil, text: "t", status: .open, deleted: false, lamport: 3, created: Date())
    let op = Op(id: UUID(), author: "A1", seq: 1, lamport: 3, kind: .annotation, payload: (try? JSON.encoder.encode(ann)) ?? Data())
    let off = FileOffer(versionID: UUID(), name: "a.jpg", size: 10, sha256: "ab", chunkSize: 262144)
    for w in [Wire.hello(Hello(peer: PeerInfo(name: "Marie", role: "client", authorID: "A1"), have: ["A1": 1])), .ops([op]), .cursor(Cursor(versionID: nil, time: 1, playing: true, page: 2)),
              .projects([ProjectInfo(id: UUID(), name: "P", client: "C", kind: .image, versions: [VersionInfo(id: UUID(), number: 1, date: Date(), file: off)])]),
              .fileRequest(FileRequest(versionID: UUID(), fromChunk: 0)), .fileDone(UUID()), .bye] {
        print(String(data: (try? JSON.encoder.encode(w)) ?? Data(), encoding: .utf8) ?? "?")
    }
    print(String(data: (try? JSON.encoder.encode(ann)) ?? Data(), encoding: .utf8) ?? "?")
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--web-demo") { exit(MainActor.assumeIsolated { SelfTest.runWebDemo(seconds: Double(CommandLine.arguments.indices.contains(i + 1) ? CommandLine.arguments[i + 1] : "60") ?? 60) }) }
if let i = CommandLine.arguments.firstIndex(of: "--bridge-demo") { exit(MainActor.assumeIsolated { SelfTest.runBridgeDemo(seconds: Double(CommandLine.arguments.indices.contains(i + 1) ? CommandLine.arguments[i + 1] : "300") ?? 300) }) }
if CommandLine.arguments.contains("--selftest-upnp") { exit(SelfTest.runUPnP()) }
if let i = CommandLine.arguments.firstIndex(of: "--join-demo"), CommandLine.arguments.indices.contains(i + 1) { exit(MainActor.assumeIsolated { SelfTest.runJoinDemo(link: CommandLine.arguments[i + 1]) }) }
if CommandLine.arguments.contains("--upnp-clean") { if let g = UPnP.discover() { print("redirections mFRAMES supprimées : \(UPnP.removeAllMine(g))") } else { print("aucune box UPnP") }; exit(0) }
if CommandLine.arguments.contains("--selftest-net") { exit(SelfTest.runNet()) }

// `mFRAMES --make-proxy fichier…` : fabrique le proxy de chaque fichier (vidéo, image, PDF, PSD, AI…) et en indique le résultat (sans fenêtre).
if let i = CommandLine.arguments.firstIndex(of: "--make-proxy") {
    setenv("MFRAMES_NO_KEYCHAIN", "1", 1)
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mframes-proxy-\(UUID().uuidString)")
    let store = ReviewStore(dir: tmp, authorName: "essai", keyService: "test")
    var failures = 0
    for path in CommandLine.arguments[(i + 1)...] {
        let ext = (path as NSString).pathExtension.lowercased()
        let kind: MediaKind = ["mp4", "mov", "m4v"].contains(ext) ? .video : ["jpg", "jpeg", "png", "tif", "tiff", "heic"].contains(ext) ? .image : ext == "pdf" ? .pdf : .design
        let v = ProjectVersion(id: UUID(), number: 1, path: path, proxyPath: nil, date: Date())
        let p = Project(id: UUID(), name: "essai", client: "", kind: kind, versions: [v], created: Date())
        var result: URL?; var finished = false
        Task { result = await ProxyMaker.make(project: p, version: v, store: store); finished = true }
        while !finished { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        if let r = result, let size = (try? r.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            let orig = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if let keep = ProcessInfo.processInfo.environment["MFRAMES_PROXY_OUT"] { try? FileManager.default.createDirectory(atPath: keep, withIntermediateDirectories: true); try? FileManager.default.copyItem(at: r, to: URL(fileURLWithPath: keep).appendingPathComponent((path as NSString).lastPathComponent + "." + r.pathExtension)) }
            print("OK  \((path as NSString).lastPathComponent) (\(kind.rawValue), \(orig / 1024) Ko) → \(r.pathExtension) \(size / 1024) Ko")
        } else { print("ÉCHEC  \((path as NSString).lastPathComponent) (\(kind.rawValue))"); failures += 1 }
    }
    try? FileManager.default.removeItem(at: tmp)
    exit(failures == 0 ? 0 : 1)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
