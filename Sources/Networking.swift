// mFRAMES — outils réseau : découverte de l'adresse publique (STUN), ouverture de port (UPnP), adresse du relais.
// Tout est lu depuis les réglages (NetworkConfig) : rien n'est propre à une infrastructure.
import Foundation
import Network
import Darwin

enum Relay {
    /// « hôte:port », « tcp://hôte:port » ou « relay://hôte:port » (port 7766 par défaut).
    static func parse(_ s: String) -> (host: String, port: UInt16)? {
        var t = s.trimmingCharacters(in: .whitespaces)
        for p in ["tcp://", "relay://", "mframes://"] where t.hasPrefix(p) { t.removeFirst(p.count) }
        guard !t.isEmpty else { return nil }
        let parts = t.split(separator: ":", maxSplits: 1).map(String.init)
        guard let host = parts.first, !host.isEmpty else { return nil }
        let port = parts.count > 1 ? UInt16(parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "/"))) : 7766
        return port.map { (host, $0) }
    }
}

enum Stun {
    /// Adresse publique vue d'un serveur STUN (requête « Binding » en UDP, RFC 5389), nil si le serveur ne répond pas.
    static func publicAddress(server: String, timeout: TimeInterval = 3) -> String? {
        var s = server; for p in ["stun:", "stuns:"] where s.hasPrefix(p) { s.removeFirst(p.count) }
        let parts = s.split(separator: ":").map(String.init)
        guard let host = parts.first else { return nil }
        let port = parts.count > 1 ? parts[1] : "3478"
        var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, port, &hints, &res) == 0, let ai = res else { return nil }
        defer { freeaddrinfo(res) }
        let fd = socket(AF_INET, SOCK_DGRAM, 0); guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var req = Data([0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42])       // Binding Request, longueur 0, cookie magique
        var tid = [UInt8](repeating: 0, count: 12); _ = SecRandomCopyBytes(kSecRandomDefault, 12, &tid); req.append(contentsOf: tid)
        let sent = req.withUnsafeBytes { sendto(fd, $0.baseAddress, req.count, 0, ai.pointee.ai_addr, ai.pointee.ai_addrlen) }
        guard sent == req.count else { return nil }
        var buf = [UInt8](repeating: 0, count: 512)
        let n = recv(fd, &buf, buf.count, 0)
        guard n >= 20, buf[0] == 0x01, buf[1] == 0x01 else { return nil }
        var i = 20
        while i + 4 <= n {
            let type = Int(buf[i]) << 8 | Int(buf[i + 1]), len = Int(buf[i + 2]) << 8 | Int(buf[i + 3])
            if (type == 0x0020 || type == 0x0001), len >= 8, buf[i + 5] == 0x01 {        // XOR-MAPPED-ADDRESS ou MAPPED-ADDRESS, IPv4
                let mask: [UInt8] = type == 0x0020 ? [0x21, 0x12, 0xA4, 0x42] : [0, 0, 0, 0]
                return (0 ..< 4).map { String(buf[i + 8 + $0] ^ mask[$0]) }.joined(separator: ".")
            }
            i += 4 + ((len + 3) & ~3)
        }
        return nil
    }
}

/// Ouverture d'un port sur la box (UPnP / IGD). Découverte et adresse externe en lecture seule ; l'ouverture n'a lieu qu'à la demande.
final class UPnP {
    struct Gateway { var controlURL: URL; var serviceType: String }

    static func discover(timeout: TimeInterval = 2.5) -> Gateway? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0); guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = UInt16(1900).bigEndian; addr.sin_addr.s_addr = inet_addr("239.255.255.250")
        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n"
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, msg, msg.utf8.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var buf = [UInt8](repeating: 0, count: 2048)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0, let reply = String(bytes: buf[0 ..< n], encoding: .utf8) else { return nil }
        guard let loc = reply.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("location:") })?.dropFirst(9).trimmingCharacters(in: .whitespaces),
              let url = URL(string: loc), let xml = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for type in ["urn:schemas-upnp-org:service:WANIPConnection:1", "urn:schemas-upnp-org:service:WANIPConnection:2", "urn:schemas-upnp-org:service:WANPPPConnection:1"] {
            guard let r = xml.range(of: type), let c = xml[r.upperBound...].range(of: "<controlURL>"), let e = xml[c.upperBound...].range(of: "</controlURL>") else { continue }
            let path = String(xml[c.upperBound ..< e.lowerBound])
            if let ctl = URL(string: path, relativeTo: url)?.absoluteURL { return Gateway(controlURL: ctl, serviceType: type) }
        }
        return nil
    }

    private static func soap(_ g: Gateway, action: String, args: String) -> String? {
        var req = URLRequest(url: g.controlURL, timeoutInterval: 4)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(g.serviceType)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        req.httpBody = Data("<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:\(action) xmlns:u=\"\(g.serviceType)\">\(args)</u:\(action)></s:Body></s:Envelope>".utf8)
        var out: String?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, r, _ in if let d, (r as? HTTPURLResponse)?.statusCode == 200 { out = String(data: d, encoding: .utf8) }; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 5)
        return out
    }

    static func externalIP(_ g: Gateway) -> String? {
        guard let x = soap(g, action: "GetExternalIPAddress", args: ""), let a = x.range(of: "<NewExternalIPAddress>"), let b = x.range(of: "</NewExternalIPAddress>") else { return nil }
        return String(x[a.upperBound ..< b.lowerBound])
    }
    @discardableResult
    static func map(_ g: Gateway, port: UInt16, localIP: String, leaseSeconds: Int = 7200) -> Bool {
        soap(g, action: "AddPortMapping", args: "<NewRemoteHost></NewRemoteHost><NewExternalPort>\(port)</NewExternalPort><NewProtocol>TCP</NewProtocol><NewInternalPort>\(port)</NewInternalPort><NewInternalClient>\(localIP)</NewInternalClient><NewEnabled>1</NewEnabled><NewPortMappingDescription>mFRAMES</NewPortMappingDescription><NewLeaseDuration>\(leaseSeconds)</NewLeaseDuration>") != nil
    }
    /// Vrai si la box connaît une redirection TCP pour ce port externe.
    static func hasMapping(_ g: Gateway, port: UInt16) -> Bool {
        soap(g, action: "GetSpecificPortMappingEntry", args: "<NewRemoteHost></NewRemoteHost><NewExternalPort>\(port)</NewExternalPort><NewProtocol>TCP</NewProtocol>") != nil
    }
    /// Supprime toutes les redirections « mFRAMES » de la box (nettoyage) ; renvoie leur nombre.
    @discardableResult
    static func removeAllMine(_ g: Gateway) -> Int {
        var ports: [UInt16] = []
        for i in 0 ..< 64 {
            guard let x = soap(g, action: "GetGenericPortMappingEntry", args: "<NewPortMappingIndex>\(i)</NewPortMappingIndex>") else { break }
            if x.contains("<NewPortMappingDescription>mFRAMES</NewPortMappingDescription>"), let a = x.range(of: "<NewExternalPort>"), let b = x.range(of: "</NewExternalPort>"), let p = UInt16(x[a.upperBound ..< b.lowerBound]) { ports.append(p) }
        }
        for p in ports { unmap(g, port: p) }
        return ports.count
    }
    static func unmap(_ g: Gateway, port: UInt16) { _ = soap(g, action: "DeletePortMapping", args: "<NewRemoteHost></NewRemoteHost><NewExternalPort>\(port)</NewExternalPort><NewProtocol>TCP</NewProtocol>") }
}
