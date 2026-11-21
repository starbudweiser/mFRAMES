// mFRAMES — présence de l'appli : Dock, barre de menus, ou les deux (préférence dans les réglages).
// Avec la barre de menus, fermer la fenêtre ne quitte pas l'appli : elle continue en arrière-plan (service)
// et se rouvre d'un clic sur son icône en couleur (silhouette du logo, sans fond).
import AppKit

enum IconMode: String, CaseIterable, Identifiable {
    case dock, menubar, both
    var id: String { rawValue }
    var label: String { L.t("settings.icon.\(rawValue)") }
    var showsDock: Bool { self != .menubar }
    var showsMenuBar: Bool { self != .dock }

    static let key = "iconMode"
    static var current: IconMode {
        get { IconMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .dock }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

@MainActor
final class Presence: NSObject {
    static let shared = Presence()
    private var item: NSStatusItem?
    var mode: IconMode { IconMode.current }

    /// Applique la préférence : politique d'activation (Dock) et icône de la barre de menus.
    func apply() {
        let m = mode
        let wanted: NSApplication.ActivationPolicy = m.showsDock ? .regular : .accessory
        if NSApp.activationPolicy() != wanted { NSApp.setActivationPolicy(wanted) }
        if m.showsMenuBar { installItem() } else { removeItem() }
    }

    func set(_ m: IconMode) {
        IconMode.current = m
        apply()
        if m == .menubar { NSApp.activate(ignoringOtherApps: true) }   // le changement de politique peut passer la fenêtre derrière
        if m != .menubar || AppDelegate.shared?.window?.isVisible == true { AppDelegate.shared?.settingsWindow?.makeKeyAndOrderFront(nil) }
    }

    private func installItem() {
        if item == nil { item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }
        guard let it = item else { return }
        it.button?.image = Self.silhouette()          // en couleur, sans fond : pas une image « modèle »
        it.button?.imagePosition = .imageOnly
        it.button?.toolTip = "mFRAMES"
        it.menu = nil                                  // jamais de it.menu (menu ouvert loin de l'icône sur plusieurs écrans) : on l'ouvre nous-mêmes
        it.button?.target = self
        it.button?.action = #selector(statusClicked)
        it.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func removeItem() {
        if let it = item { NSStatusBar.system.removeStatusItem(it) }
        item = nil
    }

    /// Cadre de lecture turquoise avec son triangle, et le point d'épingle orange : le logo sans son carré de fond.
    static func silhouette() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 15), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: rect.width / 660, y: rect.height / 520)
            ctx.translateBy(x: -185, y: -265)             // repère du logo (1024, origine en bas) recadré sur le motif
            let teal = NSColor(srgbRed: 0x2d / 255, green: 0xd4 / 255, blue: 0xbf / 255, alpha: 1)
            let frame = NSBezierPath(roundedRect: NSRect(x: 220, y: 300, width: 584, height: 424), xRadius: 78, yRadius: 78)
            frame.lineWidth = 56; teal.setStroke(); frame.stroke()
            let play = NSBezierPath(); play.move(to: NSPoint(x: 452, y: 430)); play.line(to: NSPoint(x: 452, y: 594)); play.line(to: NSPoint(x: 600, y: 512)); play.close()
            teal.setFill(); play.fill()
            NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 666, y: 608, width: 170, height: 170)).fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    private var mainVisible: Bool { AppDelegate.shared?.window?.isVisible == true && NSApp.isActive && AppDelegate.shared?.window?.isMiniaturized == false }

    /// Clic gauche : ouvre ou ferme la fenêtre. Clic droit (ou Ctrl-clic) : menu, juste sous l'icône.
    @objc private func statusClicked() {
        guard let button = item?.button else { return }
        let ev = NSApp.currentEvent
        if ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.control) == true {
            let menu = makeMenu()
            if let w = button.window {
                let r = w.convertToScreen(button.convert(button.bounds, to: nil))
                var x = r.minX
                if let sc = w.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(r) }) { x = min(max(x, sc.frame.minX), sc.frame.maxX - menu.size.width - 4) }
                menu.popUp(positioning: nil, at: NSPoint(x: x, y: r.minY - 4), in: nil)
            } else {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY + 4 : -4), in: button)
            }
        } else if mainVisible { AppDelegate.shared?.window?.close() }
        else { showMain() }
    }

    @objc func showMain() { AppDelegate.shared?.openMainWindow(show: true) }
    @objc private func showSettings() { AppDelegate.shared?.openSettings() }
    @objc private func showAbout() { AppDelegate.shared?.showAbout() }
    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func chooseMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = IconMode(rawValue: raw) else { return }
        set(m)
        if m == .dock { showMain() }     // plus d'icône ici : la fenêtre reste accessible par le Dock
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ sel: Selector) { let i = NSMenuItem(title: title, action: sel, keyEquivalent: ""); i.target = self; menu.addItem(i) }
        add(L.t("menubar.open"), #selector(showMain))
        add(L.t("menu.settings"), #selector(showSettings))
        menu.addItem(.separator())
        let icon = NSMenuItem(title: L.t("settings.icon"), action: nil, keyEquivalent: ""); let sub = NSMenu()
        for m in IconMode.allCases {
            let it = NSMenuItem(title: m.label, action: #selector(chooseMode(_:)), keyEquivalent: ""); it.target = self
            it.representedObject = m.rawValue; it.state = m == mode ? .on : .off; sub.addItem(it)
        }
        icon.submenu = sub; menu.addItem(icon)
        menu.addItem(.separator())
        add(L.t("menu.about"), #selector(showAbout))
        add(L.t("menu.quit"), #selector(quitApp))
        return menu
    }
}
