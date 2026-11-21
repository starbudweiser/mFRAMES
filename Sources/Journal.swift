// mFRAMES — journal local chiffré (SQLite). Toute modification y est écrite d'abord, avant d'être envoyée : une coupure ne perd rien.
// Les charges utiles sont chiffrées (AES-GCM) avec une clé gardée dans le Trousseau.
import Foundation
import SQLite3
import CryptoKit
import Security

enum LocalKey {
    /// Clé du journal : Trousseau ; `MFRAMES_NO_KEYCHAIN=1` (essais) : fichier à côté du journal.
    static func load(dir: URL, service: String) -> SymmetricKey {
        if ProcessInfo.processInfo.environment["MFRAMES_NO_KEYCHAIN"] != nil {
            let f = dir.appendingPathComponent("journal.key")
            if let d = try? Data(contentsOf: f), d.count == 32 { return SymmetricKey(data: d) }
            let k = SymmetricKey(size: .bits256)
            let d = k.withUnsafeBytes { Data($0) }
            try? d.write(to: f); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path)
            return k
        }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: "journal", kSecReturnData as String: true]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, d.count == 32 { return SymmetricKey(data: d) }
        let k = SymmetricKey(size: .bits256)
        let d = k.withUnsafeBytes { Data($0) }
        var add = q; add.removeValue(forKey: kSecReturnData as String); add[kSecValueData as String] = d
        SecItemAdd(add as CFDictionary, nil)
        return k
    }
}

final class Journal {
    private var db: OpaquePointer?
    private let key: SymmetricKey
    private let lock = NSLock()

    init(url: URL, key: SymmetricKey) {
        self.key = key
        sqlite3_open(url.path, &db)
        exec("PRAGMA journal_mode=WAL")
        exec("CREATE TABLE IF NOT EXISTS ops (id TEXT PRIMARY KEY, author TEXT NOT NULL, seq INTEGER NOT NULL, lamport INTEGER NOT NULL, kind TEXT NOT NULL, payload BLOB NOT NULL)")
        exec("CREATE INDEX IF NOT EXISTS ops_author_seq ON ops(author, seq)")
    }
    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private func seal(_ d: Data) -> Data { (try? AES.GCM.seal(d, using: key).combined) ?? d }
    private func open(_ d: Data) -> Data? { try? AES.GCM.open(AES.GCM.SealedBox(combined: d), using: key) }

    /// Ajoute l'opération ; faux si elle y était déjà (idempotent : une même opération reçue deux fois compte une fois).
    @discardableResult
    func append(_ op: Op) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO ops (id, author, seq, lamport, kind, payload) VALUES (?,?,?,?,?,?)", -1, &st, nil)
        defer { sqlite3_finalize(st) }
        let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(st, 1, op.id.uuidString, -1, T)
        sqlite3_bind_text(st, 2, op.author, -1, T)
        sqlite3_bind_int64(st, 3, Int64(op.seq))
        sqlite3_bind_int64(st, 4, Int64(op.lamport))
        sqlite3_bind_text(st, 5, op.kind.rawValue, -1, T)
        let blob = seal(op.payload)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(st, 6, $0.baseAddress, Int32(blob.count), T) }
        guard sqlite3_step(st) == SQLITE_DONE else { return false }
        return sqlite3_changes(db) > 0
    }

    func all() -> [Op] { query("SELECT id, author, seq, lamport, kind, payload FROM ops ORDER BY lamport, id", []) }

    /// Opérations que l'autre côté n'a pas, d'après ce qu'il annonce (`have` : plus grand numéro d'ordre connu, par auteur).
    func ops(after have: [String: Int]) -> [Op] {
        all().filter { $0.seq > (have[$0.author] ?? 0) }
    }

    /// Plus grand numéro d'ordre connu, par auteur.
    func have() -> [String: Int] {
        var h: [String: Int] = [:]
        for op in all() { h[op.author] = max(h[op.author] ?? 0, op.seq) }
        return h
    }

    private func query(_ sql: String, _ args: [String]) -> [Op] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &st, nil)
        defer { sqlite3_finalize(st) }
        var out: [Op] = []
        while sqlite3_step(st) == SQLITE_ROW {
            guard let id = UUID(uuidString: String(cString: sqlite3_column_text(st, 0))),
                  let kind = OpKind(rawValue: String(cString: sqlite3_column_text(st, 4))),
                  let p = sqlite3_column_blob(st, 5) else { continue }
            let blob = Data(bytes: p, count: Int(sqlite3_column_bytes(st, 5)))
            guard let plain = open(blob) else { continue }
            out.append(Op(id: id, author: String(cString: sqlite3_column_text(st, 1)), seq: Int(sqlite3_column_int64(st, 2)),
                          lamport: Int(sqlite3_column_int64(st, 3)), kind: kind, payload: plain))
        }
        return out
    }
}
