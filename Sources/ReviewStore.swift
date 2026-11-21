// mFRAMES — état d'une review : annotations et messages déduits du journal, horloge logique, projets.
// Écrire d'abord dans le journal, puis appliquer à l'état, puis prévenir la session (qui envoie).
import Foundation
import Combine
import CryptoKit

final class ReviewStore: ObservableObject {
    let dir: URL
    let journal: Journal
    let author: Author
    @Published private(set) var annotations: [UUID: Annotation] = [:]
    @Published private(set) var messages: [UUID: ChatMessage] = [:]
    @Published var projects: [Project] = []
    private var clock = 0
    private var seq = 0
    /// Appelée pour chaque opération locale (la session l'envoie).
    var onLocalOp: ((Op) -> Void)?

    static func dataDir(name: String) -> URL {
        if let e = ProcessInfo.processInfo.environment["MFRAMES_DATA_DIR"] { return URL(fileURLWithPath: e) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }

    init(dir: URL, authorName: String, keyService: String) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = LocalKey.load(dir: dir, service: keyService)
        journal = Journal(url: dir.appendingPathComponent("journal.sqlite"), key: key)
        // identité stable de cet appareil
        let idFile = dir.appendingPathComponent("author.id")
        let id = (try? String(contentsOf: idFile, encoding: .utf8)) ?? UUID().uuidString
        try? id.write(to: idFile, atomically: true, encoding: .utf8)
        author = Author(id: id, name: authorName, colorIndex: abs(id.hashValue) % 6)
        for op in journal.all() { clock = max(clock, op.lamport); if op.author == id { seq = max(seq, op.seq) }; apply(op) }
        if let d = try? Data(contentsOf: dir.appendingPathComponent("projects.json")), let p = try? JSON.decoder.decode([Project].self, from: d) { projects = p }
    }

    func saveProjects() {
        if let d = try? JSON.encoder.encode(projects) { try? d.write(to: dir.appendingPathComponent("projects.json"), options: .atomic) }
    }

    // MARK: Actions locales

    @discardableResult
    func addAnnotation(versionID: UUID, kind: AnnotationKind = .pin, x: Double, y: Double, w: Double = 0, h: Double = 0, time: Double? = nil, page: Int? = nil, text: String = "") -> Annotation {
        let a = Annotation(id: UUID(), versionID: versionID, author: author, kind: kind, x: x, y: y, w: w, h: h, time: time, page: page,
                           text: text, status: .open, deleted: false, lamport: 0, created: Date())
        record(a, kind: .annotation) { $0.lamport = $1 }
        return annotations[a.id] ?? a
    }

    func update(_ a: Annotation) { record(a, kind: .annotation) { $0.lamport = $1 } }
    func setStatus(_ id: UUID, _ s: ReviewStatus) { if var a = annotations[id] { a.status = s; update(a) } }
    func delete(message id: UUID) { if var m = messages[id] { m.deleted = true; record(m, kind: .message) { $0.lamport = $1 } } }
    func delete(annotation id: UUID) { if var a = annotations[id] { a.deleted = true; update(a) } }

    @discardableResult
    func addMessage(versionID: UUID, annotationID: UUID? = nil, text: String, as other: Author? = nil) -> ChatMessage {
        let m = ChatMessage(id: UUID(), versionID: versionID, annotationID: annotationID, author: other ?? author, text: text, deleted: false, lamport: 0, created: Date())
        record(m, kind: .message) { $0.lamport = $1 }
        return messages[m.id] ?? m
    }

    private func record<T: Codable>(_ value: T, kind: OpKind, stamp: (inout T, Int) -> Void) {
        var v = value
        clock += 1; seq += 1
        stamp(&v, clock)
        guard let payload = try? JSON.encoder.encode(v) else { return }
        let op = Op(id: UUID(), author: author.id, seq: seq, lamport: clock, kind: kind, payload: payload)
        journal.append(op)   // d'abord le journal : une coupure ne perd rien
        apply(op)
        onLocalOp?(op)
    }

    // MARK: Opérations reçues

    /// Reçoit des opérations de l'autre côté. Renvoie celles qui étaient nouvelles.
    @discardableResult
    func receive(_ ops: [Op]) -> [Op] {
        var fresh: [Op] = []
        for op in ops where journal.append(op) {
            clock = max(clock, op.lamport)
            apply(op)
            fresh.append(op)
        }
        return fresh
    }

    private func apply(_ op: Op) {
        switch op.kind {
        case .annotation:
            guard let a = try? JSON.decoder.decode(Annotation.self, from: op.payload) else { return }
            if let old = annotations[a.id], (old.lamport, old.id.uuidString) >= (a.lamport, a.id.uuidString) { return }   // la plus récente gagne
            annotations[a.id] = a
        case .message:
            guard let m = try? JSON.decoder.decode(ChatMessage.self, from: op.payload) else { return }
            if let old = messages[m.id], old.lamport >= m.lamport { return }
            messages[m.id] = m
        }
    }

    // MARK: Lecture

    func annotations(for versionID: UUID) -> [Annotation] {
        annotations.values.filter { $0.versionID == versionID && !$0.deleted }.sorted { ($0.time ?? 0, $0.lamport, $0.id.uuidString) < ($1.time ?? 0, $1.lamport, $1.id.uuidString) }
    }
    /// Numéro stable d'une épingle : rang de création dans la version (une nouvelle épingle prend toujours le numéro suivant,
    /// quel que soit son instant ; seule une suppression referme le trou).
    func number(of a: Annotation) -> Int {
        let order = annotations.values.filter { $0.versionID == a.versionID && !$0.deleted }.sorted { ($0.created, $0.id.uuidString) < ($1.created, $1.id.uuidString) }
        return (order.firstIndex { $0.id == a.id } ?? 0) + 1
    }
    func messages(for versionID: UUID) -> [ChatMessage] {
        messages.values.filter { $0.versionID == versionID && !$0.deleted }.sorted { ($0.lamport, $0.id.uuidString) < ($1.lamport, $1.id.uuidString) }
    }
}
