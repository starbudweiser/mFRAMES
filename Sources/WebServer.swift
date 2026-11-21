// mFRAMES — client navigateur : serveur web intégré (pages statiques + WebSocket) pour les clients sans installation.
// La page et le protocole sont les mêmes que pour l'app cliente : trames AES-GCM, clé dérivée du secret de l'invitation (dans le fragment du lien,
// jamais envoyé au serveur). Sans le secret, le WebSocket ne donne rien : la première trame est refusée et la liaison coupée.
import Foundation
import Network
import CryptoKit

enum WS {
    /// Trame serveur → navigateur (jamais masquée).
    static func frame(_ payload: Data, opcode: UInt8 = 0x2) -> Data {
        var f = Data([0x80 | opcode])
        let n = payload.count
        if n < 126 { f.append(UInt8(n)) }
        else if n < 65536 { f.append(126); f.append(UInt8(n >> 8)); f.append(UInt8(n & 0xff)) }
        else { f.append(127); var b = UInt64(n).bigEndian; f.append(Data(bytes: &b, count: 8)) }
        f.append(payload)
        return f
    }
    static func accept(key: String) -> String {
        Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }
}

/// Lit des trames WebSocket client → serveur (toujours masquées), y compris fragmentées.
struct WSParser {
    enum Message { case binary(Data), ping(Data), close, invalid }
    private var buf = Data()
    private var partial = Data()
    mutating func feed(_ d: Data) { buf.append(d) }
    mutating func next() -> Message? {
        guard buf.count >= 2 else { return nil }
        let b0 = buf[buf.startIndex], b1 = buf[buf.startIndex + 1]
        let fin = b0 & 0x80 != 0, op = b0 & 0x0f, masked = b1 & 0x80 != 0
        var len = Int(b1 & 0x7f), off = 2
        if len == 126 { guard buf.count >= 4 else { return nil }; len = Int(buf[buf.startIndex + 2]) << 8 | Int(buf[buf.startIndex + 3]); off = 4 }
        else if len == 127 {
            guard buf.count >= 10 else { return nil }
            len = (2 ..< 10).reduce(0) { $0 << 8 | Int(buf[buf.startIndex + $1]) }; off = 10
        }
        guard masked else { return .invalid }
        guard len < 70 * 1024 * 1024 else { return .invalid }
        guard buf.count >= off + 4 + len else { return nil }
        let mask = Array(buf[buf.startIndex + off ..< buf.startIndex + off + 4])
        var payload = Data(buf[buf.startIndex + off + 4 ..< buf.startIndex + off + 4 + len])
        for i in 0 ..< payload.count { payload[i] ^= mask[i & 3] }
        buf = Data(buf.dropFirst(off + 4 + len))
        switch op {
        case 0x8: return .close
        case 0x9: return .ping(payload)
        case 0xA: return next()
        case 0x0, 0x1, 0x2:
            partial.append(payload)
            if fin { defer { partial = Data() }; return .binary(partial) }
            return next()
        default: return .invalid
        }
    }
}

final class WebServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "mframes.web")
    private weak var engine: SessionEngine?
    private let root: URL
    private(set) var port: UInt16 = 0
    var onReady: ((UInt16) -> Void)?

    /// `root` : dossier des pages (dans l'app : Resources/Web).
    init(engine: SessionEngine, root: URL) { self.engine = engine; self.root = root }

    static func defaultRoot() -> URL {
        if let e = ProcessInfo.processInfo.environment["MFRAMES_WEB_DIR"] { return URL(fileURLWithPath: e) }
        return (Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")).appendingPathComponent("Web")
    }

    func start(port wanted: UInt16 = 0) throws {
        let l = try NWListener(using: .tcp, on: wanted == 0 ? .any : NWEndpoint.Port(rawValue: wanted)!)
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.stateUpdateHandler = { [weak self, weak l] st in if case .ready = st, let p = l?.port?.rawValue { self?.port = p; self?.onReady?(p) } }
        l.start(queue: queue); listener = l
    }
    func stop() { listener?.cancel(); listener = nil }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, Data())
    }
    private func read(_ c: NWConnection, _ acc: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] d, _, done, e in
            guard let self else { return }
            var buf = acc; if let d { buf.append(d) }
            if buf.count > 16384 || e != nil { c.cancel(); return }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.route(c, head: String(decoding: buf[..<r.lowerBound], as: UTF8.self), leftover: Data(buf[r.upperBound...]))
            } else if done { c.cancel() } else { self.read(c, buf) }
        }
    }

    private func respond(_ c: NWConnection, _ status: String, mime: String, body: Data) {
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
    }

    private func route(_ c: NWConnection, head: String, leftover: Data) {
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ").map(String.init)
        guard first.count >= 2, first[0] == "GET" else { return respond(c, "405 Method Not Allowed", mime: "text/plain", body: Data("GET seulement".utf8)) }
        func header(_ n: String) -> String? { lines.dropFirst().first { $0.lowercased().hasPrefix(n.lowercased() + ":") }.map { String($0.dropFirst(n.count + 1)).trimmingCharacters(in: .whitespaces) } }
        let path = first[1].split(separator: "?").first.map(String.init) ?? "/"
        if path == "/ws", header("Upgrade")?.lowercased() == "websocket", let key = header("Sec-WebSocket-Key"), let engine {
            let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(WS.accept(key: key))\r\n\r\n"
            c.send(content: Data(resp.utf8), completion: .contentProcessed { [weak self] e in
                guard e == nil else { c.cancel(); return }
                let link = SecureLink(c, key: engine.invitation.key)
                self?.engine?.adopt(link, leftover: leftover)
            })
            return
        }
        let files: [String: (String, String)] = ["/": ("index.html", "text/html; charset=utf-8"), "/index.html": ("index.html", "text/html; charset=utf-8"), "/app.js": ("app.js", "text/javascript; charset=utf-8"),
                                                 "/crypto.js": ("crypto.js", "text/javascript; charset=utf-8"), "/style.css": ("style.css", "text/css; charset=utf-8")]
        guard let (name, mime) = files[path], let data = try? Data(contentsOf: root.appendingPathComponent(name)) else { return respond(c, "404 Not Found", mime: "text/plain", body: Data("introuvable".utf8)) }
        respond(c, "200 OK", mime: mime, body: data)
    }
}
