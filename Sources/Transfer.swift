// mFRAMES — proxys légers (jamais les originaux) et cache du client : copie locale complète, blocs reprenables, vérification d'empreinte.
// Le client garde sa copie : une coupure ne l'empêche pas de continuer sa review ; la copie suit la durée du lien et peut être effacée.
import Foundation
import AVFoundation
import AppKit
import CryptoKit
import ImageIO
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

// MARK: Hôte : génération des proxys

enum ProxyMaker {
    /// Dossier des proxys de l'hôte.
    static func dir(_ store: ReviewStore) -> URL {
        let d = store.dir.appendingPathComponent("proxies"); try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d
    }

    /// Fabrique (ou retrouve) le proxy d'une version : vidéo H.264 1280×720, image JPEG ≤ 2560 px, PDF tel quel, autres formats (PSD, AI…) : aperçu composite.
    static func make(project: Project, version: ProjectVersion, store: ReviewStore) async -> URL? {
        let src = URL(fileURLWithPath: version.path)
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        let base = dir(store).appendingPathComponent(version.id.uuidString)
        let mtime = ((try? src.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()).timeIntervalSince1970
        func fresh(_ u: URL) -> Bool {
            guard let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return false }
            return m.timeIntervalSince1970 >= mtime
        }
        switch project.kind {
        case .video:
            let out = base.appendingPathExtension("mp4")
            if fresh(out) { return out }
            try? FileManager.default.removeItem(at: out)
            let asset = AVURLAsset(url: src)
            guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return nil }
            ex.outputURL = out; ex.outputFileType = .mp4; ex.shouldOptimizeForNetworkUse = true
            await ex.export()
            return ex.status == .completed ? out : nil
        case .image:
            return jpeg(from: src, to: base.appendingPathExtension("jpg"), fresh: fresh)
        case .pdf:
            let out = base.appendingPathExtension("pdf")
            if !fresh(out) { try? FileManager.default.removeItem(at: out); try? FileManager.default.copyItem(at: src, to: out) }
            return FileManager.default.fileExists(atPath: out.path) ? out : nil
        case .design:
            // .ai est un PDF ; PSD, INDD, XD… : aperçu composite (ImageIO, sinon Quick Look)
            if src.pathExtension.lowercased() == "ai", PDFDocument(url: src) != nil {
                let out = base.appendingPathExtension("pdf")
                if !fresh(out) { try? FileManager.default.removeItem(at: out); try? FileManager.default.copyItem(at: src, to: out) }
                return out
            }
            let out = base.appendingPathExtension("jpg")
            if let j = jpeg(from: src, to: out, fresh: fresh) { return j }
            let req = QLThumbnailGenerator.Request(fileAt: src, size: CGSize(width: 2048, height: 2048), scale: 1, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req), writeJPEG(rep.cgImage, to: out) { return out }
            return nil
        }
    }

    private static func jpeg(from src: URL, to out: URL, fresh: (URL) -> Bool) -> URL? {
        if fresh(out) { return out }
        guard let s = CGImageSourceCreateWithURL(src as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2560]
        guard let img = CGImageSourceCreateThumbnailAtIndex(s, 0, opts as CFDictionary) else { return nil }
        return writeJPEG(img, to: out) ? out : nil
    }
    private static func writeJPEG(_ img: CGImage, to out: URL) -> Bool {
        guard let d = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(d)
    }

    static func offer(for file: URL, versionID: UUID) -> FileOffer? {
        guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return FileOffer(versionID: versionID, name: file.lastPathComponent, size: size, sha256: sha256(file) ?? "", chunkSize: SessionEngine.chunkSize)
    }

    static func sha256(_ url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var h = SHA256()
        while let d = try? fh.read(upToCount: 1 << 20), !d.isEmpty { h.update(data: d) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: Client : cache local

/// Cache du client : un fichier partiel par version (`.part`), promu en copie complète quand l'empreinte est bonne.
final class ClientCache {
    let dir: URL
    private let lock = NSLock()
    init(dir: URL) { self.dir = dir.appendingPathComponent("cache"); try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true) }

    func final(_ offer: FileOffer) -> URL { dir.appendingPathComponent("\(offer.versionID.uuidString)-\(offer.name)") }
    func part(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).part") }
    func has(_ offer: FileOffer) -> Bool { (try? final(offer).resourceValues(forKeys: [.fileSizeKey]))?.fileSize == offer.size }

    /// Premier bloc manquant (reprise) d'après ce qui est déjà sur le disque.
    func nextChunk(for offer: FileOffer) -> Int {
        let size = (try? part(offer.versionID).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size / offer.chunkSize
    }
    func bytesHave(_ offer: FileOffer) -> Int {
        has(offer) ? offer.size : min(offer.size, ((try? part(offer.versionID).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
    }

    /// Écrit un bloc s'il est bien le suivant (les autres sont ignorés : doublon après reprise).
    @discardableResult
    func write(chunk index: Int, data: Data, for offer: FileOffer) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let u = part(offer.versionID)
        if !FileManager.default.fileExists(atPath: u.path) { FileManager.default.createFile(atPath: u.path, contents: nil) }
        guard index == nextChunkLocked(offer), let fh = try? FileHandle(forWritingTo: u) else { return false }
        defer { try? fh.close() }
        try? fh.seekToEnd(); try? fh.write(contentsOf: data)
        return true
    }
    private func nextChunkLocked(_ offer: FileOffer) -> Int {
        ((try? part(offer.versionID).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) / offer.chunkSize
    }

    /// Vérifie taille et empreinte ; la copie devient définitive, sinon elle est jetée (on repart de zéro).
    func complete(_ offer: FileOffer) -> URL? {
        lock.lock(); defer { lock.unlock() }
        let p = part(offer.versionID)
        guard (try? p.resourceValues(forKeys: [.fileSizeKey]))?.fileSize == offer.size, ProxyMaker.sha256(p) == offer.sha256 else { try? FileManager.default.removeItem(at: p); return nil }
        let f = final(offer)
        try? FileManager.default.removeItem(at: f)
        do { try FileManager.default.moveItem(at: p, to: f) } catch { return nil }
        return f
    }

    func remove(versionID: UUID) {
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent.hasPrefix(versionID.uuidString) { try? FileManager.default.removeItem(at: f) }
    }

    /// Plafond d'espace : les copies les plus anciennes sont effacées d'abord.
    func evict(maxBytes: Int, keep: Set<UUID>) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey])) ?? [])
        var total = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        for f in files.sorted(by: { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast < (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }) where total > maxBytes {
            if let id = UUID(uuidString: String(f.lastPathComponent.prefix(36))), keep.contains(id) { continue }
            total -= (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? FileManager.default.removeItem(at: f)
        }
    }
    func clear() { try? FileManager.default.removeItem(at: dir); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
}
