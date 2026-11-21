// mFRAMES — données de démonstration (MFRAMES_DEMO=1) : une image, des retours d'un client fictif. Sert aux captures et aux essais sans fenêtre.
import AppKit

@MainActor
enum DemoData {
    /// Texte de démonstration : français sur un Mac en français, anglais sinon (captures en anglais).
    private static func D(_ fr: String, _ en: String) -> String { L.lang == .fr ? fr : en }
    static var enabled: Bool { ProcessInfo.processInfo.environment["MFRAMES_DEMO"] != nil }

    static func load(into model: AppModel) {
        let dir = model.store.dir
        let img = dir.appendingPathComponent("demo-affiche.png")
        let s = NSSize(width: 1600, height: 900)
        let image = NSImage(size: s)
        image.lockFocus()
        NSColor(srgbRed: 0.114, green: 0.169, blue: 0.227, alpha: 1).setFill(); NSRect(origin: .zero, size: s).fill()
        NSColor(srgbRed: 1, green: 0.70, blue: 0.25, alpha: 1).setFill(); NSBezierPath(ovalIn: NSRect(x: 1080, y: 520, width: 220, height: 220)).fill()
        NSColor(srgbRed: 0.075, green: 0.125, blue: 0.176, alpha: 1).setFill()
        let mt = NSBezierPath(); mt.move(to: NSPoint(x: 0, y: 0)); mt.line(to: NSPoint(x: 0, y: 420)); mt.line(to: NSPoint(x: 320, y: 600)); mt.line(to: NSPoint(x: 600, y: 380)); mt.line(to: NSPoint(x: 940, y: 640)); mt.line(to: NSPoint(x: 1280, y: 360)); mt.line(to: NSPoint(x: 1600, y: 500)); mt.line(to: NSPoint(x: 1600, y: 0)); mt.fill()
        NSColor.white.withAlphaComponent(0.93).setFill(); NSBezierPath(roundedRect: NSRect(x: 160, y: 640, width: 560, height: 86), xRadius: 14, yRadius: 14).fill()
        NSColor.white.withAlphaComponent(0.5).setFill(); NSBezierPath(roundedRect: NSRect(x: 160, y: 590, width: 380, height: 28), xRadius: 14, yRadius: 14).fill()
        image.unlockFocus()
        if let t = image.tiffRepresentation, let r = NSBitmapImageRep(data: t), let png = r.representation(using: .png, properties: [:]) { try? png.write(to: img) }

        let v1 = ProjectVersion(id: UUID(), number: 1, path: img.path, proxyPath: nil, date: Date().addingTimeInterval(-86400))
        let v2 = ProjectVersion(id: UUID(), number: 2, path: img.path, proxyPath: nil, date: Date())
        let p = Project(id: UUID(), name: D("Affiche A2", "A2 poster"), client: "Boutique Aurore", kind: .image, versions: [v1, v2], created: Date())
        let p2 = Project(id: UUID(), name: D("Spot 30 s", "30 s spot"), client: "Boutique Aurore", kind: .video, versions: [ProjectVersion(id: UUID(), number: 3, path: "", proxyPath: nil, date: Date())], created: Date())
        let p3 = Project(id: UUID(), name: "Catalogue", client: "Boutique Aurore", kind: .pdf, versions: [ProjectVersion(id: UUID(), number: 2, path: "", proxyPath: nil, date: Date())], created: Date())
        let p4 = Project(id: UUID(), name: "Logo", client: "Maison Verne", kind: .design, versions: [ProjectVersion(id: UUID(), number: 1, path: "", proxyPath: nil, date: Date())], created: Date())
        model.store.projects = [p, p2, p3, p4]
        if ProcessInfo.processInfo.environment["MFRAMES_DEMO_SELECT"] == "spot" { model.selectedProjectID = p2.id; model.selectedVersionID = p2.versions[0].id }
        else { model.selectedProjectID = p.id; model.selectedVersionID = v2.id }

        // retours de Marie (auteur fictif), reçus comme s'ils venaient du réseau
        let marie = Author(id: "demo-marie", name: "Marie", colorIndex: 4)
        func op(_ seq: Int, _ lamport: Int, _ kind: OpKind, _ value: some Encodable) -> Op {
            Op(id: UUID(), author: marie.id, seq: seq, lamport: lamport, kind: kind, payload: (try? JSON.encoder.encode(value)) ?? Data())
        }
        let a1 = Annotation(id: UUID(), versionID: v2.id, author: marie, kind: .pin, x: 0.23, y: 0.22, w: 0, h: 0, time: nil, page: nil, text: D("Le titre est trop petit, on peut l'agrandir ?", "The title is too small, can we make it bigger?"), status: .open, deleted: false, lamport: 1, created: Date())
        let a2 = Annotation(id: UUID(), versionID: v2.id, author: marie, kind: .zone, x: 0.10, y: 0.12, w: 0.36, h: 0.14, time: nil, page: nil, text: D("Cette zone est trop chargée.", "This area feels too busy."), status: .open, deleted: false, lamport: 3, created: Date())
        let m1 = ChatMessage(id: UUID(), versionID: v2.id, annotationID: a1.id, author: model.store.author, text: D("Je l'agrandis maintenant, nouvelle version dans 10 s.", "Making it bigger now, new version in 10 s."), deleted: false, lamport: 2, created: Date())
        let a3 = Annotation(id: UUID(), versionID: v2.id, author: marie, kind: .pin, x: 0.74, y: 0.30, w: 0, h: 0, time: nil, page: nil, text: D("Le soleil pourrait être plus petit.", "The sun could be a little smaller."), status: .resolved, deleted: false, lamport: 4, created: Date())
        // retours datés sur la vidéo « Spot 30 s » (essais des modules de montage)
        let spot = p2.versions[0].id
        let sa1 = Annotation(id: UUID(), versionID: spot, author: marie, kind: .pin, x: 0.46, y: 0.12, w: 0, h: 0, time: 2.0, page: nil, text: D("Le titre est trop petit", "The title is too small"), status: .open, deleted: false, lamport: 5, created: Date())
        let sa2 = Annotation(id: UUID(), versionID: spot, author: marie, kind: .pin, x: 0.7, y: 0.3, w: 0, h: 0, time: 5.5, page: nil, text: D("Logo coupé à droite", "Logo cut off on the right"), status: .open, deleted: false, lamport: 6, created: Date())
        let sa3 = Annotation(id: UUID(), versionID: spot, author: marie, kind: .pin, x: 0.3, y: 0.6, w: 0, h: 0, time: 9.0, page: nil, text: D("Fondu à revoir", "Fade needs another pass"), status: .resolved, deleted: false, lamport: 7, created: Date())
        model.store.receive([op(1, 1, .annotation, a1), op(2, 3, .annotation, a2), op(3, 4, .annotation, a3), op(4, 5, .annotation, sa1), op(5, 6, .annotation, sa2), op(6, 7, .annotation, sa3)])
        model.store.addMessage(versionID: v2.id, annotationID: a1.id, text: m1.text)
    }
}
