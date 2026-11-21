// mFRAMES — cycle de vie, fenêtre principale, menus, essais sans fenêtre au premier plan (`--silent`, `--capture`).
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate?
    var window: NSWindow?
    var settingsWindow: NSWindow?
    var aboutWindow: NSWindow?
    let args = CommandLine.arguments
    func arg(_ name: String) -> String? { args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : "" } }

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        let model = AppModel.shared
        if DemoData.enabled { DemoData.load(into: model) }
        if let t = arg("--theme"), let a = Appearance(rawValue: t) { model.appearance = a } else { model.applyAppearance() }
        buildMenu()
        let silent = args.contains("--silent") || arg("--capture") != nil || arg("--capture-invite") != nil
        UpdateEngine.shared.configure(repo: "mFRAMES", lang: { L.lang == .fr ? "fr" : L.lang == .es ? "es" : L.lang == .it ? "it" : "en" }, brandName: "mFRAMES")
        UpdateEngine.shared.autoInstall = { UserDefaults.standard.bool(forKey: "autoUpdate") }
        if !AppModel.isDev, !silent { UpdateEngine.shared.start() }
        if !silent { Presence.shared.apply() }
        if let out = arg("--capture-invite") { openMainWindow(show: false); model.showInvite = true; model.startHosting(); capture(to: out, delay: 1.6); return }
        if let out = arg("--capture") { openMainWindow(show: false); capture(to: out, delay: Double(arg("--delay") ?? "") ?? 0.8); return }
        if args.contains("--silent") { openMainWindow(show: false); return }
        openMainWindow(show: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { openMainWindow(show: true) }; return true }

    // MARK: Fenêtre principale

    func openMainWindow(show: Bool) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
            w.minSize = NSSize(width: 900, height: 560)
            w.backgroundColor = Theme.chatNS
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MainView(model: AppModel.shared))
            w.setFrame(NSRect(x: 0, y: 0, width: 1160, height: 720), display: false)
            centerHigh(w)
            window = w
        }
        guard show else { return }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Adapte la fenêtre à la taille du média (jamais au-delà de 1920 × 1080 ni de l'écran) ; le média est réduit, jamais agrandi.
    func fitWindow(toMedia size: CGSize) {
        guard let w = window, size.width > 0, size.height > 0, !w.styleMask.contains(.fullScreen), !w.isZoomed,
              let s = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
        let chromeW = M.panel + M.comments + 4 * M.gap, chromeH = 36 + 3 * M.gap + 2
        let maxW = min(1920, s.width), maxH = min(1080, s.height)
        let k = min(1, (maxW - chromeW) / size.width, (maxH - chromeH) / size.height)
        let tw = min(maxW, max(w.minSize.width, size.width * k + chromeW)), th = min(maxH, max(w.minSize.height, size.height * k + chromeH))
        let old = w.frame
        var f = NSRect(x: old.midX - tw / 2, y: old.maxY - th, width: tw, height: th)   // le haut de la fenêtre ne bouge pas
        f.origin.x = min(max(f.origin.x, s.minX), s.maxX - f.width); f.origin.y = min(max(f.origin.y, s.minY), s.maxY - f.height)
        if abs(old.width - f.width) > 1 || abs(old.height - f.height) > 1 { w.setFrame(f, display: true, animate: !M.reduceMotion) }
    }

    func centerHigh(_ w: NSWindow) {
        guard let s = NSScreen.main?.visibleFrame else { w.center(); return }
        w.setFrameOrigin(NSPoint(x: s.midX - w.frame.width / 2, y: s.midY - w.frame.height / 2 + s.height * 0.03))
    }

    // MARK: Captures (essais sans fenêtre au premier plan)

    func capture(to path: String, delay: Double = 0.8) {
        guard let w = window, let v = w.contentView else { exit(2) }
        // laisser SwiftUI composer sa première image
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            v.frame = NSRect(origin: .zero, size: w.frame.size); print("FENETRE \(Int(w.frame.width))x\(Int(w.frame.height))")
            v.layoutSubtreeIfNeeded()
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { exit(3) }
            v.cacheDisplay(in: v.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)); print("OK : \(path)") }
            exit(0)
        }
    }

    // MARK: Menus

    func buildMenu() {
        let main = NSMenu()
        func item(_ title: String, _ sel: Selector?, _ key: String = "", target: AnyObject? = nil, mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key); i.keyEquivalentModifierMask = mods; i.target = target ?? self; return i
        }
        let app = NSMenu()
        app.addItem(item(L.t("menu.about"), #selector(showAbout)))
        UpdateEngine.shared.installAppMenuItem()
        app.addItem(.separator())
        app.addItem(item(L.t("menu.settings"), #selector(openSettings), ","))
        app.addItem(.separator())
        let hide = NSMenuItem(title: L.t("menu.hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"); hide.target = NSApp; app.addItem(hide)
        app.addItem(.separator())
        let q = NSMenuItem(title: L.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); q.target = NSApp; app.addItem(q)
        let appItem = NSMenuItem(); appItem.submenu = app; main.addItem(appItem)

        let file = NSMenu(title: L.t("menu.file"))
        file.addItem(item(L.t("projects.new"), #selector(newProject), "n"))
        file.addItem(item(L.t("session.invite"), #selector(invite), "i"))
        file.addItem(item(L.t("session.join"), #selector(joinSession), "j"))
        let exportItem = NSMenuItem(title: L.t("menu.exportMarkers"), action: nil, keyEquivalent: ""); let exportMenu = NSMenu()
        for (key, ext) in [("edl", "edl"), ("fcpxml", "fcpxml"), ("premiere", "xml"), ("aejsx", "jsx"), ("csv", "csv")] {
            let i = NSMenuItem(title: L.t("export." + key), action: #selector(exportMarkers(_:)), keyEquivalent: ""); i.target = self; i.representedObject = [key, ext]; exportMenu.addItem(i)
        }
        exportItem.submenu = exportMenu; file.addItem(exportItem)
        let fileItem = NSMenuItem(); fileItem.submenu = file; main.addItem(fileItem)

        let edit = NSMenu(title: L.t("menu.edit"))
        for (t, s, k) in [(L.t("menu.undo"), #selector(UndoManager.undo), "z"), (L.t("menu.copy"), #selector(NSText.copy(_:)), "c"), (L.t("menu.paste"), #selector(NSText.paste(_:)), "v"), (L.t("menu.selectAll"), #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: t, action: s, keyEquivalent: k))
        }
        let editItem = NSMenuItem(); editItem.submenu = edit; main.addItem(editItem)

        let win = NSMenu(title: L.t("menu.window"))
        win.addItem(NSMenuItem(title: L.t("menu.minimize"), action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        let winItem = NSMenuItem(); winItem.submenu = win; main.addItem(winItem)
        NSApp.mainMenu = main; NSApp.windowsMenu = win
    }

    @objc func exportMarkers(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], let v = AppModel.shared.version else { return }
        let fps = AppModel.shared.frameRate()
        guard let (content, _) = AppModel.shared.bridgeExport(versionID: v.id, format: pair[0], fps: fps) else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "\(AppModel.shared.project?.name ?? "mFRAMES")-V\(v.number)-marqueurs.\(pair[1])"
        if panel.runModal() == .OK, let u = panel.url { try? content.write(to: u, atomically: true, encoding: .utf8) }
    }

    @objc func newProject() { AppModel.shared.chooseFile() }
    @objc func invite() { AppModel.shared.showInvite = true; AppModel.shared.startHosting(); openMainWindow(show: true) }
    @objc func joinSession() {
        let a = NSAlert(); a.messageText = L.t("session.join.title"); a.informativeText = L.t("session.join.help")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)); a.accessoryView = f
        a.addButton(withTitle: L.t("session.join.button")); a.addButton(withTitle: L.t("invite.cancel"))
        if a.runModal() == .alertFirstButtonReturn { AppModel.shared.join(link: f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 580), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.backgroundColor = Theme.chatNS; w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: AppModel.shared)); w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showAbout() {
        aboutWindow?.close()
        let info = Bundle.main.infoDictionary ?? [:]
        let v = info["CFBundleShortVersionString"] as? String ?? "?", b = info["CFBundleVersion"] as? String ?? "?"
        func label(_ s: String, size: CGFloat = 12, bold: Bool = false, secondary: Bool = false) -> NSTextField {
            let f = NSTextField(wrappingLabelWithString: s); let p = NSMutableParagraphStyle(); p.alignment = .center
            let a = NSMutableAttributedString(string: s, attributes: [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), .paragraphStyle: p, .foregroundColor: secondary ? NSColor.secondaryLabelColor : NSColor.labelColor])
            if let r = s.range(of: "mFRAMES") { a.addAttribute(.foregroundColor, value: Theme.brandNS, range: NSRange(s.index(r.lowerBound, offsetBy: 0) ..< s.index(r.lowerBound, offsetBy: 1), in: s)) }
            f.attributedStringValue = a; f.alignment = .center; f.preferredMaxLayoutWidth = 300; f.isSelectable = false; f.translatesAutoresizingMaskIntoConstraints = false
            return f
        }
        let icon = NSImageView(image: NSApp.applicationIconImage); icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 84).isActive = true; icon.heightAnchor.constraint(equalToConstant: 84).isActive = true
        let stack = NSStackView(views: [icon, label("mFRAMES", size: 17, bold: true), label(L.t("about.version", v, b), secondary: true), label(L.t("app.tagline")),
                                        label("Starbudweiser & Claude Code (Anthropic)", bold: true), label(L.t("about.collection"), secondary: true)])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 10; stack.edgeInsets = NSEdgeInsets(top: 34, left: 28, bottom: 28, right: 28)
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.contentView = stack; w.isReleasedWhenClosed = false; w.title = ""
        w.setContentSize(stack.fittingSize); w.center()
        aboutWindow = w; NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
    }
}

extension Theme {
    static let chatNS = NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(srgbRed: 0x13 / 255, green: 0x13 / 255, blue: 0x16 / 255, alpha: 1) : NSColor(srgbRed: 0xf5 / 255, green: 0xf5 / 255, blue: 0xf7 / 255, alpha: 1) }
}
