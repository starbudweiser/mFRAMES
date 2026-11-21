// mFRAMES — export des retours en marqueurs pour les logiciels de montage : EDL (DaVinci Resolve), FCPXML (Final Cut Pro, Resolve),
// XML Premiere (xmeml), script After Effects (.jsx) et CSV. Fonctionne sans module d'intégration.
import Foundation

struct MarkerRow {
    var number: Int
    var time: Double          // secondes
    var text: String
    var author: String
    var status: ReviewStatus
}

enum MarkerExport {
    static func rows(store: ReviewStore, versionID: UUID) -> [MarkerRow] {
        let all = store.annotations(for: versionID)
        return all.enumerated().map { i, a in
            let replies = store.messages(for: versionID).filter { $0.annotationID == a.id }.map { "[\($0.author.name)] \($0.text)" }
            let text = ([a.text.isEmpty ? "—" : a.text] + replies).joined(separator: " | ")
            return MarkerRow(number: i + 1, time: a.time ?? 0, text: text, author: a.author.name, status: a.status)
        }
    }

    static func tc(_ t: Double, fps: Double) -> String {
        let total = Int((t * fps).rounded()); let f = Int(fps.rounded())
        return String(format: "%02d:%02d:%02d:%02d", total / (f * 3600), total / (f * 60) % 60, total / f % 60, total % f)
    }
    private static func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") }
    private static func label(_ r: MarkerRow) -> String { "\(r.status == .resolved ? "✓" : "●") #\(r.number) \(r.author)" }

    /// EDL CMX 3600 avec marqueurs : Resolve › Timeline › Importer › Marqueurs de la timeline depuis un EDL.
    static func edl(_ rows: [MarkerRow], fps: Double, title: String) -> String {
        var s = "TITLE: \(title)\nFCM: NON-DROP FRAME\n\n"
        for (i, r) in rows.enumerated() {
            let a = tc(r.time, fps: fps), b = tc(r.time + 1 / fps, fps: fps)
            s += String(format: "%03d  001      V     C        %@ %@ %@ %@\n", i + 1, a, b, a, b)
            s += " |C:\(r.status == .resolved ? "ResolveColorGreen" : "ResolveColorRed") |M:\(label(r)) — \(r.text) |D:1\n\n"
        }
        return s
    }

    /// FCPXML 1.10 : un projet « mFRAMES » dont un plan vide porte les marqueurs ; Final Cut Pro l'importe comme un événement.
    static func fcpxml(_ rows: [MarkerRow], fps: Double, title: String, duration: Double) -> String {
        let fd = "100/\(Int(fps * 100))s"                         // durée d'une image, par ex. 100/2500s
        func t(_ x: Double) -> String { "\(Int((x * fps).rounded()) * 100)/\(Int(fps * 100))s" }
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>\n<fcpxml version=\"1.10\">\n  <resources><format id=\"r1\" name=\"FFVideoFormat1080p\(Int(fps))\" frameDuration=\"\(fd)\" width=\"1920\" height=\"1080\"/></resources>\n"
        s += "  <library><event name=\"mFRAMES\"><project name=\"\(esc(title))\"><sequence format=\"r1\" duration=\"\(t(max(duration, (rows.last?.time ?? 0) + 1)))\" tcStart=\"0s\" tcFormat=\"NDF\"><spine>\n"
        s += "    <gap name=\"mFRAMES\" offset=\"0s\" start=\"0s\" duration=\"\(t(max(duration, (rows.last?.time ?? 0) + 1)))\">\n"
        for r in rows { s += "      <marker start=\"\(t(r.time))\" duration=\"\(fd)\" value=\"\(esc(label(r)) + " — " + esc(r.text))\"\(r.status == .resolved ? " completed=\"1\"" : "")/>\n" }
        s += "    </gap>\n  </spine></sequence></project></event></library>\n</fcpxml>\n"
        return s
    }

    /// XML « xmeml » (Premiere Pro : Fichier › Importer) : séquence vide avec marqueurs.
    static func premiereXML(_ rows: [MarkerRow], fps: Double, title: String, duration: Double) -> String {
        let frames = Int((max(duration, (rows.last?.time ?? 0) + 1) * fps).rounded())
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE xmeml>\n<xmeml version=\"4\">\n  <sequence id=\"mframes\"><name>\(esc(title))</name><duration>\(frames)</duration>\n    <rate><timebase>\(Int(fps.rounded()))</timebase><ntsc>FALSE</ntsc></rate>\n"
        for r in rows {
            let f = Int((r.time * fps).rounded())
            s += "    <marker><name>\(esc(label(r)))</name><comment>\(esc(r.text))</comment><in>\(f)</in><out>\(f + 1)</out></marker>\n"
        }
        s += "    <media><video><track></track></video></media>\n  </sequence>\n</xmeml>\n"
        return s
    }

    /// Script After Effects : Fichier › Scripts › Exécuter un fichier de script ; ajoute les marqueurs à la composition active.
    static func afterEffectsScript(_ rows: [MarkerRow]) -> String {
        let data = rows.map { r in "{n:\(r.number),t:\(String(format: "%.3f", r.time)),s:\(r.status == .resolved ? 1 : 0),a:\(jsString(r.author)),x:\(jsString(r.text))}" }.joined(separator: ",\n  ")
        return """
        // mFRAMES — retours du client en marqueurs de composition (généré).
        (function () {
          var rows = [\n  \(data)\n];
          var comp = app.project.activeItem;
          if (!(comp instanceof CompItem)) { alert("mFRAMES : ouvrez une composition."); return; }
          app.beginUndoGroup("mFRAMES : marqueurs");
          for (var i = 0; i < rows.length; i++) {
            var r = rows[i];
            var m = new MarkerValue((r.s ? "✓ " : "● ") + "#" + r.n + " " + r.a + " — " + r.x);
            m.duration = 0;
            comp.markerProperty.setValueAtTime(r.t, m);
          }
          app.endUndoGroup();
          alert("mFRAMES : " + rows.length + " marqueur(s) ajouté(s).");
        })();

        """
    }
    private static func jsString(_ s: String) -> String {
        let e = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: " ")
        return "\"\(e)\""
    }

    static func csv(_ rows: [MarkerRow], fps: Double) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return "numero,timecode,secondes,image,auteur,statut,texte\n" + rows.map { "\($0.number),\(tc($0.time, fps: fps)),\(String(format: "%.3f", $0.time)),\(Int(($0.time * fps).rounded())),\(q($0.author)),\($0.status.rawValue),\(q($0.text))" }.joined(separator: "\n") + "\n"
    }
}
