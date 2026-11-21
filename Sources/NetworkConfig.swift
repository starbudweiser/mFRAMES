// mFRAMES — réglages réseau : tout ce qui touche à l'infrastructure est configurable (produit distribuable, pas seulement pour un poste).
// Valeurs par défaut : fonctionnent sans réglage sur un réseau domestique (découverte locale, connexion directe).
import Foundation

struct NetworkConfig: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case auto          // essaie dans l'ordre : réseau local, direct, STUN, relais
        case lanOnly       // réseau local seulement : aucun serveur
        case directOnly    // adresse et port directs seulement
        case relayOnly     // relais seulement (masque l'adresse IP)
    }
    var mode: Mode = .auto
    /// Point de rencontre : adresse du serveur de signalisation (wss://…). Vide : aucun.
    var rendezvousURL: String = ""
    var stunServers: [String] = ["stun:stun.l.google.com:19302"]
    var turnServers: [String] = []
    var listenPort: UInt16 = 0            // 0 : port libre
    var useUPnP: Bool = false             // ouvre un port sur la box : à activer volontairement
    var proxy: String = ""                // http://hôte:port ou socks5://hôte:port
    var webClient: Bool = true            // serveur web intégré : le client ouvre un lien dans son navigateur, sans rien installer
    var bonjour: Bool { mode == .auto || mode == .lanOnly }

    init() {}
    /// Lecture tolérante : un fichier de réglages d'une version plus ancienne (clés manquantes) reste lisible.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: Keys.self)
        mode = (try? c.decode(Mode.self, forKey: .mode)) ?? .auto
        rendezvousURL = (try? c.decode(String.self, forKey: .rendezvousURL)) ?? ""
        stunServers = (try? c.decode([String].self, forKey: .stunServers)) ?? ["stun:stun.l.google.com:19302"]
        turnServers = (try? c.decode([String].self, forKey: .turnServers)) ?? []
        listenPort = (try? c.decode(UInt16.self, forKey: .listenPort)) ?? 0
        useUPnP = (try? c.decode(Bool.self, forKey: .useUPnP)) ?? false
        proxy = (try? c.decode(String.self, forKey: .proxy)) ?? ""
        webClient = (try? c.decode(Bool.self, forKey: .webClient)) ?? true
    }
    private enum Keys: String, CodingKey { case mode, rendezvousURL, stunServers, turnServers, listenPort, useUPnP, proxy, webClient }

    static func load(dir: URL) -> NetworkConfig {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("network.json")), let c = try? JSON.decoder.decode(NetworkConfig.self, from: d) else { return NetworkConfig() }
        return c
    }
    func save(dir: URL) { if let d = try? JSON.encoder.encode(self) { try? d.write(to: dir.appendingPathComponent("network.json"), options: .atomic) } }
}
