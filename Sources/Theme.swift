// mFRAMES — Flat Round Design (famille Flat Mat de Socle, plus arrondie et plus colorée) : couleurs, rayons, surfaces mates.
// Valeurs des maquettes validées le 16/11/2026 (maquettes/maquettes-v4.html) ; surfaces opaques, filet de 0,5 px, ombre seulement pour ce qui flotte.
import AppKit
import SwiftUI

enum M {
    static let panel: CGFloat = 268
    static let comments: CGFloat = 292
    static let gap: CGFloat = 8
    static let panelRadius: CGFloat = 12
    static let cardRadius: CGFloat = 12
    static let sheetRadius: CGFloat = 26
    static let topRow: CGFloat = 46
    static let rowHeight: CGFloat = 36
    static let barHeight: CGFloat = 44
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var spring: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 1) }
}

enum Theme {
    static func dyn(_ dark: UInt32, _ light: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let isDark = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
    static let chat = dyn(0x131316, 0xf5f5f7)          // fond de fenêtre
    static let win = dyn(0x1c1c1f, 0xffffff)           // carte de contenu
    static let solid = dyn(0x232327, 0xffffff)         // surface posée
    static let solid2 = dyn(0x2c2c31, 0xffffff)        // surface flottante
    static let stage = dyn(0x0c0c0e, 0xe6e6ea)         // fond des médias
    static let fill = Color.primary.opacity(0.08)
    static let fill2 = Color.primary.opacity(0.15)
    static let sep = Color(nsColor: .separatorColor)
    static let text2 = Color(nsColor: .secondaryLabelColor)
    static let text3 = Color(nsColor: .tertiaryLabelColor)
    static let accent = Color.accentColor
    static let green = Color(nsColor: .systemGreen)
    static let red = Color(nsColor: .systemRed)
    static let orange = dyn(0xff9f0a, 0xc46a00)
    /// Couleur de marque : la lettre minuscule du nom « mFRAMES » (règle « Nom de l'appli »).
    static let brand = dyn(0x2dd4bf, 0x0d9488)
    static let brandNS = NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0x2d / 255, green: 0xd4 / 255, blue: 0xbf / 255, alpha: 1) : NSColor(srgbRed: 0x0d / 255, green: 0x94 / 255, blue: 0x88 / 255, alpha: 1) }
    static let palette: [Color] = [Color(hex: 0x5e5ce6), Color(hex: 0xff9f0a), Color(hex: 0xff453a), Color(hex: 0x30b0c7), Color(hex: 0xbf5af2), Color(hex: 0x30d158)]
    static func person(_ index: Int) -> Color { palette[abs(index) % palette.count] }
}

extension Color {
    init(hex: UInt32) { self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255) }
}

/// Texte où la lettre minuscule du nom « mFRAMES » prend la couleur de marque.
func brandText(_ s: String) -> Text {
    var a = AttributedString(s)
    var from = a.startIndex
    while let r = a[from...].range(of: "mFRAMES") {
        a[r.lowerBound ..< a.index(r.lowerBound, offsetByCharacters: 1)].foregroundColor = Theme.brand
        from = r.upperBound
    }
    return Text(a)
}

private struct SurfaceModifier: ViewModifier {
    var radius: CGFloat
    var floating: Bool
    var fill: Color
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background { floating ? AnyView(shape.fill(fill).shadow(color: .black.opacity(0.22), radius: 16, y: 12)) : AnyView(shape.fill(fill)) }
            .overlay { shape.strokeBorder(Theme.sep, lineWidth: 0.5).allowsHitTesting(false) }
    }
}

extension View {
    /// Surface mate arrondie : posée (panneau, capsules) ou flottante (feuille, dock, bulles), avec son ombre.
    func surface(radius: CGFloat = M.panelRadius, floating: Bool = false, fill: Color? = nil) -> some View {
        modifier(SurfaceModifier(radius: radius, floating: floating, fill: fill ?? (floating ? Theme.solid2 : Theme.solid)))
    }
}

/// Bouton en pilule (remplissage discret), principal (couleur d'accent) ou rond.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var round = false
    var height: CGFloat = 34
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, round ? 0 : 16)
            .frame(width: round ? height : nil, height: height)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(prominent ? Theme.accent : (configuration.isPressed ? Theme.fill2 : Theme.fill)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct Avatar: View {
    var name: String
    var index: Int
    var size: CGFloat = 22
    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size).background(Circle().fill(Theme.person(index)))
    }
}

struct StatusPill: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 9).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color.opacity(0.16)))
    }
}

/// Pastille carrée arrondie d'un type de contenu (rayon 27 %).
struct KindTile: View {
    var kind: MediaKind
    var size: CGFloat = 24
    var color: Color { switch kind { case .video: Color(hex: 0x5e5ce6); case .image: Color(hex: 0xff9f0a); case .pdf: Color(hex: 0xff453a); case .design: Color(hex: 0x30b0c7) } }
    var symbol: String { switch kind { case .video: "film"; case .image: "photo"; case .pdf: "doc.text"; case .design: "square.3.layers.3d" } }
    var body: some View {
        Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size, height: size).background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(color))
    }
}
