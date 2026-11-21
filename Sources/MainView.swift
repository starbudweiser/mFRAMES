// mFRAMES — fenêtre principale (maquette 1 : « Session en direct ») : panneau des projets, capsules d'état, carte du média, retours en bulles.
import SwiftUI
import AVKit
import CoreImage.CIFilterBuiltins

struct MainView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ZStack {
            Theme.chat.ignoresSafeArea()
            HStack(spacing: M.gap) {
                ProjectPanel(model: model)
                VStack(spacing: M.gap) {
                    TopBar(model: model)
                    HStack(spacing: M.gap) {
                        MediaCard(model: model)
                        CommentsPanel(model: model)
                    }
                }
            }
            .padding(M.gap)
            if model.showInvite { InviteSheet(model: model).transition(.opacity) }
        }
        .animation(M.spring, value: model.showInvite)
        .frame(minWidth: 900, minHeight: 560)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            providers.first?.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                guard let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) else { return }
                DispatchQueue.main.async { model.addProject(url: u) }
            }
            return true
        }
    }
}

// MARK: Panneau latéral

struct ProjectPanel: View {
    @ObservedObject var model: AppModel
    var grouped: [(String, [Project])] {
        let list = model.projects.filter { model.search.isEmpty || $0.name.localizedCaseInsensitiveContains(model.search) || $0.client.localizedCaseInsensitiveContains(model.search) }
        return Dictionary(grouping: list, by: { $0.client }).map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // nom de l'appli : centré dans la largeur du panneau, sur l'axe des boutons de la fenêtre (centre à 23 px du haut du panneau)
            brandText("mFRAMES").font(.system(size: 14, weight: .bold)).lineLimit(1)
                .frame(maxWidth: .infinity).frame(height: M.topRow - 10).offset(y: -6)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.text2)
                TextField(L.t("projects.search"), text: $model.search).textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 12).frame(height: 32).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill)).padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if model.projects.isEmpty {
                        Text(L.t("projects.empty")).font(.system(size: 12)).foregroundStyle(Theme.text2).padding(12)
                    }
                    ForEach(grouped, id: \.0) { client, projects in
                        // en-tête de groupe : le client ; « Sans client » seulement s'il y a aussi des clients
                        let title = client.isEmpty ? (grouped.count > 1 ? L.t("projects.noClient") : L.t("projects.title")) : client
                        HStack(spacing: 6) {
                            Image(systemName: client.isEmpty ? "tray" : "person.crop.square").font(.system(size: 10, weight: .semibold))
                            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.4).lineLimit(1)
                        }.foregroundStyle(Theme.text3).padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 2)
                        ForEach(projects) { p in
                            ProjectRow(model: model, project: p)
                            // les versions sont rangées sous leur projet, jamais à part
                            if p.id == model.selectedProjectID {
                                VStack(alignment: .leading, spacing: 1) {
                                    ForEach(p.versions.sorted { $0.number > $1.number }) { v in
                                        let open = model.store.annotations(for: v.id).filter { $0.status == .open }.count
                                        HStack(spacing: 8) {
                                            Text("V\(v.number)").font(.system(size: 12, weight: .semibold).monospacedDigit())
                                            Text(v.date.formatted(.relative(presentation: .named))).font(.system(size: 11.5)).foregroundStyle(Theme.text2).lineLimit(1)
                                            Spacer()
                                            if open > 0 { Text("\(open)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.orange) }
                                        }
                                        .padding(.horizontal, 10).frame(height: 28)
                                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill((model.version?.id == v.id) ? Theme.fill2 : .clear))
                                        .contentShape(Rectangle()).onTapGesture { model.selectedVersionID = v.id }
                                        .contextMenu { Button(L.t("version.delete"), role: .destructive) { if confirmDelete(L.t("version.delete.confirm", "V\(v.number)")) { model.deleteVersion(project: p.id, version: v.id) } } }
                                    }
                                }
                                .padding(.leading, 22).overlay(alignment: .leading) { Rectangle().fill(Theme.sep).frame(width: 1).padding(.leading, 12).padding(.vertical, 2) }
                                .padding(.bottom, 4)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button { model.chooseFile() } label: { Label(L.t("projects.new"), systemImage: "plus").labelStyle(.titleAndIcon).frame(maxWidth: .infinity) }
                    .buttonStyle(PillButtonStyle())
                Button { model.showSettings = true; AppDelegate.shared?.openSettings() } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(PillButtonStyle(round: true))
            }.padding(.top, 6)
        }
        .padding(10).frame(width: M.panel).surface(radius: M.panelRadius)
    }
}

struct ProjectRow: View {
    @ObservedObject var model: AppModel
    var project: Project
    var body: some View {
        let open = project.versions.flatMap { model.store.annotations(for: $0.id) }.filter { $0.status == .open }.count
        HStack(spacing: 10) {
            KindTile(kind: project.kind)
            VStack(alignment: .leading, spacing: 0) {
                Text(project.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(project.versions.count > 1 ? L.t("versions.count", project.versions.count) : "V\(project.versions.first?.number ?? 1)").font(.system(size: 11)).foregroundStyle(Theme.text2)
            }
            Spacer()
            if open > 0 { Text("\(open)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 6).frame(minWidth: 20, minHeight: 18).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.red)) }
        }
        .padding(.horizontal, 10).frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(project.id == model.selectedProjectID ? Theme.fill2 : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedProjectID = project.id; model.selectedVersionID = project.currentVersion?.id }
        .contextMenu {
            Button(L.t("project.rename")) { if let n = askText(L.t("project.rename"), project.name) { model.updateProject(project.id, name: n) } }
            Menu(L.t("project.client")) {
                Button(L.t("projects.noClient")) { model.updateProject(project.id, client: "") }
                ForEach(model.clients, id: \.self) { c in Button(c + (c == project.client ? "  ✓" : "")) { model.updateProject(project.id, client: c) } }
                Divider()
                Button(L.t("project.newClient")) { if let n = askText(L.t("project.newClient"), project.client) { model.updateProject(project.id, client: n) } }
            }
            Divider()
            Button(L.t("project.delete"), role: .destructive) { if confirmDelete(L.t("project.delete.confirm", project.name)) { model.deleteProject(project.id) } }
        }
    }
}

/// Confirmation avant suppression (le fichier d'origine n'est jamais effacé).
@MainActor func confirmDelete(_ message: String) -> Bool {
    let a = NSAlert(); a.alertStyle = .warning; a.messageText = message; a.informativeText = L.t("project.delete.info")
    a.addButton(withTitle: L.t("project.delete.ok")); a.addButton(withTitle: L.t("common.cancel"))
    return a.runModal() == .alertFirstButtonReturn
}

/// Petite boîte de saisie (nom de projet, client).
@MainActor func askText(_ title: String, _ value: String) -> String? {
    let a = NSAlert(); a.messageText = title
    let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.stringValue = value; a.accessoryView = f
    a.addButton(withTitle: "OK"); a.addButton(withTitle: L.t("common.cancel"))
    a.window.initialFirstResponder = f
    return a.runModal() == .alertFirstButtonReturn ? f.stringValue : nil
}

// MARK: Barre du haut

struct TopBar: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                Image(systemName: "chevron.left").frame(width: 32, height: 30)
                Image(systemName: "chevron.right").frame(width: 32, height: 30).foregroundStyle(Theme.text3)
            }.font(.system(size: 13, weight: .medium)).padding(.horizontal, 6).frame(height: 36).surface(radius: 10)
            if let p = model.project {
                HStack(spacing: 10) {
                    KindTile(kind: p.kind, size: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(p.name) · V\(model.version?.number ?? 1)").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(p.client.isEmpty ? p.kind.rawValue : p.client).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1)
                    }
                }.padding(.leading, 8).padding(.trailing, 18).frame(height: M.barHeight).surface(radius: 12)
            }
            Spacer()
            if let v = model.version, model.session?.role == .client, let f = model.transfers[v.id] {
                HStack(spacing: 8) {
                    Image(systemName: f >= 1 ? "checkmark.circle.fill" : "arrow.down.circle").foregroundStyle(f >= 1 ? Theme.green : Theme.accent).font(.system(size: 13))
                    Text(L.t("cache.local", Int(f * 100))).font(.system(size: 12.5, weight: .medium))
                }.padding(.horizontal, 14).frame(height: 36).surface(radius: 10)
            }
            SessionCapsule(model: model)
            if model.session != nil {
                Button { model.follow.toggle(); if model.follow { model.broadcastCursor() } } label: {
                    HStack(spacing: 8) { Image(systemName: "scope").font(.system(size: 12)); Text(L.t("session.follow")); Toggle("", isOn: $model.follow).toggleStyle(.switch).labelsHidden().scaleEffect(0.7).frame(width: 34) }
                }.buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).padding(.horizontal, 14).frame(height: 36).surface(radius: 10)
            }
            Button { model.showInvite = true; model.startHosting() } label: { Label(L.t("session.invite"), systemImage: "person.crop.circle.badge.plus") }
                .buttonStyle(PillButtonStyle(prominent: true, height: 36))
        }
        .frame(height: M.barHeight)
    }
}

struct SessionCapsule: View {
    @ObservedObject var model: AppModel
    var text: (String, Color)? {
        switch model.sessionState {
        case .idle: nil
        case .listening: (L.t("session.listening"), Theme.text2)
        case .connecting: (L.t("session.listening"), Theme.text2)
        case .connected: (L.t("session.connected", model.peer?.name ?? "?"), Theme.green)
        case .reconnecting(let n): (L.t("session.reconnecting", n), Theme.orange)
        case .refused: (L.t("session.offline"), Theme.red)
        }
    }
    var body: some View {
        if let (t, c) = text {
            HStack(spacing: 8) {
                if let p = model.peer { Avatar(name: p.name, index: abs(p.authorID.hashValue) % 6, size: 22) }
                Circle().fill(c).frame(width: 8, height: 8)
                Text(t).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            }.padding(.horizontal, 14).frame(height: 36).surface(radius: 10)
        }
    }
}

// MARK: Carte du média

struct MediaCard: View {
    @ObservedObject var model: AppModel
    let player: PlayerController   // non observé : sinon toute la carte se redessine 25 fois par seconde
    init(model: AppModel) { self.model = model; player = model.player }

    var body: some View {
        ZStack {
            Theme.stage
            if let v = model.version, let p = model.project {
                MediaSurface(model: model, project: p, version: v, player: player)
                VStack {
                    ToolsCapsule(model: model)
                    Spacer()
                    if p.kind == .video { PlayerDock(model: model, player: player) }
                }.padding(14)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.text3)
                    Text(L.t("projects.empty")).font(.system(size: 13)).foregroundStyle(Theme.text2)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: M.cardRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: M.cardRadius, style: .continuous).strokeBorder(Theme.sep, lineWidth: 0.5) }
        .onChange(of: model.version?.id) { _ in
            if let v = model.version, model.project?.kind == .video { player.load(path: v.mediaPath) }
            fitToMedia()
        }
        .onReceive(player.$naturalSize) { fitToMedia(video: $0) }   // @Published émet avant la mise à jour : on prend la valeur reçue
        .onAppear { if let v = model.version, model.project?.kind == .video { player.load(path: v.mediaPath) }; fitToMedia() }
    }

    /// Fenêtre à la taille du média : vidéo (dès que sa taille est lue), image / maquette (pixels).
    func fitToMedia(video: CGSize? = nil) {
        guard let v = model.version, let p = model.project else { return }
        var size = CGSize.zero
        if p.kind == .video { size = video ?? player.naturalSize }
        else if p.kind == .image || p.kind == .design, let rep = NSImageRep(contentsOfFile: v.mediaPath) { size = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh) }
        if size.width > 0 { AppDelegate.shared?.fitWindow(toMedia: size) }
    }
}

struct ToolsCapsule: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 4) {
            tool(.pin, "mappin.and.ellipse"); tool(.zone, "rectangle.dashed")
            if let v = model.version, model.isPDF(v), model.pageCount > 1 {
                Divider().frame(height: 20)
                Button { model.goToPage(model.page - 1) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 34) }.buttonStyle(.plain)
                Text(L.t("page.of", model.page + 1, model.pageCount)).font(.system(size: 12, weight: .medium).monospacedDigit())
                Button { model.goToPage(model.page + 1) } label: { Image(systemName: "chevron.right").frame(width: 28, height: 34) }.buttonStyle(.plain)
            }
        }.padding(5).surface(radius: 12, floating: true)
    }
    func tool(_ k: AnnotationKind, _ symbol: String) -> some View {
        Button { model.tool = k } label: { Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 34, height: 34)
            .foregroundStyle(model.tool == k ? Color.white : Color.primary).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(model.tool == k ? Theme.accent : .clear)) }
            .buttonStyle(.plain).help(k == .pin ? L.t("tool.pin") : L.t("tool.zone"))
    }
}

/// Média + épingles. Un clic pose une épingle, un glissé dessine une zone ; coordonnées de 0 à 1 dans l'image.
struct MediaSurface: View {
    @ObservedObject var model: AppModel
    var project: Project
    var version: ProjectVersion
    @ObservedObject var player: PlayerController
    @State private var dragStart: CGPoint?
    @State private var dragNow: CGPoint?

    func fit(_ size: CGSize, content: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return CGRect(origin: .zero, size: size) }
        let k = min(size.width / content.width, size.height / content.height)
        let w = content.width * k, h = content.height * k
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    var image: NSImage? {
        if model.isPDF(version) { _ = model.page; return model.pdfImage() }
        return project.kind == .image || project.kind == .design ? NSImage(contentsOfFile: version.mediaPath) : nil
    }
    var contentSize: CGSize {
        if let i = image { return i.size }
        if let s = player.player.currentItem?.presentationSize, s.width > 0 { return s }
        return CGSize(width: 16, height: 9)
    }

    var body: some View {
        GeometryReader { g in
            let r = fit(g.size, content: contentSize)
            ZStack(alignment: .topLeading) {
                if project.kind == .video { VideoLayerView(player: player.player).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY) }
                else if let i = image { Image(nsImage: i).resizable().frame(width: r.width, height: r.height).clipShape(RoundedRectangle(cornerRadius: 6)).offset(x: r.minX, y: r.minY) }
                else if version.mediaPath.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView(value: model.transfers[version.id] ?? 0).frame(width: 180)
                        Text(L.t("cache.waiting") + (model.transfers[version.id].map { "  \(Int($0 * 100)) %" } ?? "")).font(.system(size: 13)).foregroundStyle(Theme.text2)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.questionmark").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.text3)
                        Text((version.mediaPath as NSString).lastPathComponent).font(.system(size: 13, weight: .semibold))
                        Text(L.t("media.unsupported")).font(.system(size: 12)).foregroundStyle(Theme.text2).multilineTextAlignment(.center).frame(maxWidth: 360)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // annotations
                let all = model.store.annotations(for: version.id)
                let list = all.map { (model.store.number(of: $0), $0) }.filter { model.isPDF(version) ? ($0.1.page ?? 0) == model.page : true }
                ForEach(list, id: \.1.id) { n, a in
                    if project.kind != .video || a.time == nil || player.frame(of: player.time) == player.frame(of: a.time ?? 0) {   // l'épingle n'est visible que sur l'image exacte de son instant
                        marker(n, a, in: r)
                    }
                }
                if let s = dragStart, let e = dragNow, model.tool == .zone {
                    RoundedRectangle(cornerRadius: 8).stroke(Theme.red, lineWidth: 2).frame(width: abs(e.x - s.x), height: abs(e.y - s.y)).offset(x: min(s.x, e.x), y: min(s.y, e.y))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in dragStart = v.startLocation; dragNow = v.location }
                .onEnded { v in
                    defer { dragStart = nil; dragNow = nil }
                    guard r.contains(v.startLocation) else { return }
                    // un clic sur un marqueur existant le sélectionne (géré par le marqueur) : jamais de doublon
                    let onMarker = model.store.annotations(for: version.id).contains { a in
                        (project.kind != .video || a.time == nil || player.frame(of: player.time) == player.frame(of: a.time ?? 0))
                        && (!model.isPDF(version) || (a.page ?? 0) == model.page)
                        && hypot(v.startLocation.x - (r.minX + a.x * r.width), v.startLocation.y - (r.minY + a.y * r.height)) < 16
                    }
                    if onMarker { return }
                    let nx = (v.startLocation.x - r.minX) / r.width, ny = (v.startLocation.y - r.minY) / r.height
                    let moved = hypot(v.location.x - v.startLocation.x, v.location.y - v.startLocation.y) > 8
                    let t: Double? = project.kind == .video ? player.time : nil
                    let pg: Int? = model.isPDF(version) ? model.page : nil
                    let a: Annotation
                    if model.tool == .zone, moved {
                        let ex = (v.location.x - r.minX) / r.width, ey = (v.location.y - r.minY) / r.height
                        a = model.store.addAnnotation(versionID: version.id, kind: .zone, x: min(nx, ex), y: min(ny, ey), w: abs(ex - nx), h: abs(ey - ny), time: t, page: pg)
                    } else {
                        a = model.store.addAnnotation(versionID: version.id, kind: .pin, x: nx, y: ny, time: t, page: pg)
                    }
                    model.selectedAnnotation = a.id
                })
        }
    }

    @ViewBuilder func marker(_ n: Int, _ a: Annotation, in r: CGRect) -> some View {
        let color: Color = a.status == .resolved ? Theme.green : Theme.person(a.author.colorIndex)
        if a.kind == .zone {
            RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 2).frame(width: a.w * r.width, height: a.h * r.height).offset(x: r.minX + a.x * r.width, y: r.minY + a.y * r.height)
        }
        Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white).frame(width: 26, height: 26)
            .background(Circle().fill(color)).overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: model.selectedAnnotation == a.id ? 3 : 2))
            .offset(x: r.minX + a.x * r.width - 13, y: r.minY + a.y * r.height - 13)
            .onTapGesture { model.selectedAnnotation = a.id; if let t = a.time { player.seek(t) } }
            .contextMenu { Button(L.t("comments.delete"), role: .destructive) { model.store.delete(annotation: a.id); if model.selectedAnnotation == a.id { model.selectedAnnotation = nil } } }
    }
}

struct VideoLayerView: NSViewRepresentable {
    var player: AVPlayer
    func makeNSView(context: Context) -> NSView {
        let v = NSView(); v.wantsLayer = true
        let l = AVPlayerLayer(player: player); l.videoGravity = .resizeAspect; l.cornerRadius = 6; l.masksToBounds = true
        v.layer = l; return v
    }
    func updateNSView(_ v: NSView, context: Context) { (v.layer as? AVPlayerLayer)?.player = player }
}

/// Clavier du lecteur : Espace lecture / pause, ← → image par image (⇧ : 10 images). Laisse passer les touches quand on tape dans un champ de texte.
final class PlayerKeys {
    private var monitor: Any?
    func install(_ p: PlayerController) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if let t = NSApp.keyWindow?.firstResponder as? NSText, !t.string.isEmpty { return e }   // on tape un commentaire : les touches lui reviennent
            if !e.modifierFlags.intersection([.command, .option, .control]).isEmpty { return e }
            switch e.keyCode {
            case 49: MainActor.assumeIsolated { p.toggle() }; return nil
            case 123: MainActor.assumeIsolated { p.step(frames: e.modifierFlags.contains(.shift) ? -10 : -1) }; return nil
            case 125: MainActor.assumeIsolated { p.jump(toMarker: false) }; return nil
            case 126: MainActor.assumeIsolated { p.jump(toMarker: true) }; return nil
            case 124: MainActor.assumeIsolated { p.step(frames: e.modifierFlags.contains(.shift) ? 10 : 1) }; return nil
            default: return e
            }
        }
    }
    func remove() { if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil }
    deinit { remove() }
}

struct PlayerDock: View {
    @State private var keys = PlayerKeys()
    @State private var hoverX: CGFloat?
    @AppStorage("dockCollapsed") private var collapsed = false
    @ObservedObject var model: AppModel
    @ObservedObject var player: PlayerController

    func tc(_ t: Double) -> String {
        let fps = max(1, Int(player.fps.rounded())), total = max(0, Int((t * player.fps).rounded())), f = total % fps, sec = total / fps
        return sec >= 3600 ? String(format: "%d:%02d:%02d:%02d", sec / 3600, sec / 60 % 60, sec % 60, f) : String(format: "%02d:%02d:%02d", sec / 60, sec % 60, f)
    }
    var marks: [Annotation] { model.store.annotations(for: model.version?.id ?? UUID()).filter { $0.time != nil } }

    func tbtn(_ symbol: String, size: CGFloat = 13, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: size, weight: .semibold)).frame(width: 30, height: 30).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(Color.primary.opacity(0.85)).help(help)
    }

    var scrubber: some View {
        GeometryReader { g in
            let d = max(player.duration, 0.001), w = g.size.width
            let f = min(1, max(0, player.time / d))
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill2).frame(height: 6)
                Capsule().fill(Theme.accent).frame(width: w * f, height: 6)
                ForEach(marks) { a in
                    let x = w * ((a.time ?? 0) / d)
                    Capsule().fill(a.status == .resolved ? Theme.green : Theme.orange).frame(width: 3, height: 16).offset(x: x - 1.5)
                        .onTapGesture { model.selectedAnnotation = a.id; player.seek(a.time ?? 0) }
                }
                Capsule().fill(.white).frame(width: 3, height: 22).shadow(color: .black.opacity(0.35), radius: 2).offset(x: w * f - 1.5)
                if let hx = hoverX {
                    Text(tc(Double(hx / w) * player.duration)).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.8)))
                        .offset(x: min(max(0, hx - 30), w - 60), y: -26)
                }
            }
            .frame(maxHeight: .infinity).contentShape(Rectangle())
            .onContinuousHover { ph in if case .active(let p) = ph { hoverX = min(max(0, p.x), w) } else { hoverX = nil } }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in player.seek(Double(min(1, max(0, v.location.x / w))) * player.duration, exact: false) }
                .onEnded { v in player.seek(Double(min(1, max(0, v.location.x / w))) * player.duration) })
        }.frame(height: 24)
    }

    /// Version réduite : une petite pastille (temps, lecture, déplier) qui laisse l'image libre.
    var compact: some View {
        HStack(spacing: 8) {
            Text(tc(player.time)).font(.system(size: 13, weight: .semibold).monospacedDigit())
            Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 11)).foregroundStyle(.white).frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accent)).contentShape(Rectangle()) }.buttonStyle(.plain).help("␣")
            tbtn("chevron.up", size: 11, help: L.t("player.expand")) { withAnimation(.snappy) { collapsed = false } }
        }
        .padding(.horizontal, 12).padding(.vertical, 5).surface(radius: 10, floating: true)
    }

    var body: some View {
        Group { if collapsed { compact } else { full } }
        .onAppear { keys.install(player); player.markers = marks.compactMap(\.time) }
        .onChange(of: marks.map(\.time)) { _ in player.markers = marks.compactMap(\.time) }
        .onDisappear { keys.remove() }
    }

    var full: some View {
        VStack(spacing: 6) {
            scrubber
            HStack(spacing: 4) {
                (Text(tc(player.time)).font(.system(size: 17, weight: .semibold).monospacedDigit()) + Text("  / \(tc(player.duration))").font(.system(size: 12).monospacedDigit()).foregroundColor(Theme.text2))
                    .frame(width: 190, alignment: .leading)
                Spacer()
                tbtn("backward.end.fill", help: "↓  " + L.t("player.prevMarker")) { player.jump(toMarker: false) }
                tbtn("backward.frame.fill", help: "←") { player.step(frames: -1) }
                Button { player.toggle() } label: { Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 15)).foregroundStyle(.white).frame(width: 40, height: 40).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accent)).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("␣")
                tbtn("forward.frame.fill", help: "→") { player.step(frames: 1) }
                tbtn("forward.end.fill", help: "↑  " + L.t("player.nextMarker")) { player.jump(toMarker: true) }
                Spacer()
                Menu {
                    ForEach([0.25, 0.5, 1.0, 1.5, 2.0], id: \.self) { v in Button((v == 1 ? "1×" : String(format: "%g×", v)) + (player.speed == v ? "  ✓" : "")) { player.setSpeed(v) } }
                } label: { Text(String(format: "%g×", player.speed)).font(.system(size: 12, weight: .semibold).monospacedDigit()).frame(width: 40, height: 26).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(L.t("player.speed"))
                tbtn("repeat", size: 12, help: L.t("player.loop")) { player.loop.toggle() }.foregroundStyle(player.loop ? Theme.accent : Color.primary.opacity(0.6))
                tbtn(player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: 12, help: L.t("player.mute")) { player.muted.toggle() }
                tbtn("chevron.down", size: 11, help: L.t("player.collapse")) { withAnimation(.snappy) { collapsed = true } }
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8).surface(radius: 12, floating: true)
    }
}

// MARK: Retours

struct CommentsPanel: View {
    @ObservedObject var model: AppModel
    @State private var draft = ""
    @StateObject private var dictation = Dictation()
    @FocusState private var inputFocused: Bool
    @State private var inputFrame: CGRect = .zero      // zone de saisie, en coordonnées de la fenêtre (origine en haut à gauche)
    @State private var clickMonitor: Any?
    private var inputExpanded: Bool { inputFocused || dictation.active || !draft.isEmpty }
    enum Item: Identifiable { case annotation(Int, Annotation), message(ChatMessage)
        var id: UUID { switch self { case .annotation(_, let a): a.id; case .message(let m): m.id } }
        var lamport: Int { switch self { case .annotation(_, let a): a.lamport; case .message(let m): m.lamport } } }
    var items: [Item] {
        guard let v = model.version else { return [] }
        let a = model.store.annotations(for: v.id).map { Item.annotation(model.store.number(of: $0), $0) }
        let m = model.store.messages(for: v.id).map { Item.message($0) }
        return (a + m).sorted { $0.lamport < $1.lamport }
    }
    func tc(_ t: Double) -> String { let fps = max(1, Int(model.player.fps.rounded())), n = max(0, Int((t * model.player.fps).rounded())); return String(format: "%02d:%02d:%02d", n / fps / 60, n / fps % 60, n % fps) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L.t("comments.title")).font(.system(size: 15, weight: .bold)).lineLimit(1).layoutPriority(1)
                if let v = model.version { StatusPill(text: "\(model.store.annotations(for: v.id).filter { $0.status == .open }.count)", color: Theme.accent).lineLimit(1).fixedSize().help(L.t("comments.open", model.store.annotations(for: v.id).filter { $0.status == .open }.count)) }
                Spacer()
                if let v = model.version {
                    let sent = model.lastSentLamport(v.id) >= (model.store.annotations(for: v.id).map(\.lamport).max() ?? 0) && model.submissions.contains { $0.versionID == v.id }
                    Button { model.sendToAgent() } label: { Label(sent ? L.t("comments.sent") : L.t("comments.send"), systemImage: sent ? "checkmark" : "paperplane.fill").font(.system(size: 12, weight: .semibold)) }
                        .buttonStyle(SendButtonStyle(sent: sent)).fixedSize().layoutPriority(2).help(L.t("comments.sendHelp"))
                }
            }.padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(items) { item in
                            switch item {
                            case .annotation(let n, let a): bubble(author: a.author, text: a.text.isEmpty ? "\(L.t("tool.pin")) \(n)" : a.text, chip: a.time.map(tc) ?? "\(L.t(a.kind == .pin ? "tool.pin" : "tool.zone")) \(n)", annotation: a).id(item.id)
                            case .message(let m): bubble(author: m.author, text: m.text, chip: nil, annotation: nil, messageID: m.id).id(item.id)
                            }
                        }
                    }.padding(.horizontal, 14).padding(.vertical, 6)
                }
                .onChange(of: items.count) { _ in if let last = items.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            }
            HStack(alignment: inputExpanded ? .bottom : .center, spacing: 8) {
                TextField(dictation.active ? L.t("voice.listening") : L.t("comments.placeholder"), text: $draft, axis: .vertical).lineLimit(1...12).textFieldStyle(.plain).font(.system(size: 13)).focused($inputFocused).onSubmit(send)
                    .frame(maxWidth: .infinity, minHeight: inputExpanded ? 128 : 32, alignment: inputExpanded ? .topLeading : .leading).padding(.top, inputExpanded ? 8 : 0).offset(y: inputExpanded ? 0 : 3).onExitCommand { inputFocused = false }
                Menu {
                    Button { dictation.selectedUID = "" } label: { Label(L.t("voice.sourceDefault"), systemImage: dictation.selectedUID.isEmpty ? "checkmark" : "") }
                    ForEach(dictation.sources) { src in
                        Button { dictation.selectedUID = src.id } label: { Label(src.name, systemImage: dictation.selectedUID == src.id ? "checkmark" : "") }
                    }
                } label: { Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).frame(width: 22, height: 32) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("\(L.t("voice.source")) : \(dictation.selectedName)")
                    .onAppear { dictation.refreshSources() }
                Button { dictation.toggle(current: draft) { draft = $0 } } label: { Image(systemName: dictation.active ? "stop.fill" : "mic.fill").font(.system(size: 12, weight: .bold)) }
                    .buttonStyle(PillButtonStyle(prominent: dictation.active, round: true, height: 32)).help(dictation.active ? L.t("voice.stop") : L.t("voice.start"))
                Button(action: send) { Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold)) }.buttonStyle(PillButtonStyle(prominent: true, round: true, height: 32)).disabled(draft.isEmpty)
            }
            .padding(.leading, 16).padding(.trailing, 6).padding(.vertical, 6).background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill)).contentShape(Rectangle()).onTapGesture { inputFocused = true }
            .background(GeometryReader { g in Color.clear.onAppear { inputFrame = g.frame(in: .global) }.onChange(of: g.frame(in: .global)) { inputFrame = $0 } })
            .animation(.interpolatingSpring(stiffness: 170, damping: 11), value: inputExpanded).padding(12)
            if let e = dictation.error {
                VStack(alignment: .leading, spacing: 4) {
                    Text(e).font(.system(size: 11)).foregroundStyle(Theme.red)
                    if dictation.denied { Button(L.t("voice.openSettings")) { dictation.openPrivacy() }.buttonStyle(.link).font(.system(size: 11)) }
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .frame(width: M.comments).surface(radius: M.panelRadius)
        .onAppear {
            // un clic hors de la zone de saisie lui retire le focus : elle se réduit (le brouillon, lui, reste)
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { ev in
                if inputFocused, let w = ev.window, let h = w.contentView?.bounds.height {
                    let p = CGPoint(x: ev.locationInWindow.x, y: h - ev.locationInWindow.y)
                    if !inputFrame.insetBy(dx: -2, dy: -2).contains(p) { inputFocused = false; w.makeFirstResponder(nil) }
                }
                return ev
            }
        }
        .onDisappear { if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil } }
    }

    func send() {
        guard !draft.isEmpty, let v = model.version, let p = model.project else { return }
        dictation.stop()
        if model.selectedAnnotation == nil || model.store.annotations[model.selectedAnnotation!] == nil {
            // Pas d'épingle sélectionnée : on en pose une au centre, à l'image exacte de la tête de lecture.
            let t: Double? = p.kind == .video ? model.player.time : nil
            let pg: Int? = model.isPDF(v) ? model.page : nil
            let a = model.store.addAnnotation(versionID: v.id, kind: .pin, x: 0.5, y: 0.5, time: t, page: pg, text: draft)
            model.selectedAnnotation = a.id
        } else { model.store.addMessage(versionID: v.id, annotationID: model.selectedAnnotation, text: draft) }
        draft = ""
    }

    /// Saute à l'épingle : instant exact dans la vidéo, page dans un PDF.
    func goTo(_ a: Annotation) {
        model.selectedAnnotation = a.id
        if let t = a.time { model.player.seek(t) }
        if let pg = a.page, pg != model.page { model.page = pg }
    }

    func bubble(author: Author, text: String, chip: String?, annotation: Annotation?, messageID: UUID? = nil) -> some View {
        let mine = author.id == model.store.author.id
        let placeholder = annotation?.text.isEmpty == true   // épingle sans texte : bulle « Épingle N », en gris discret
        return VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 6) { if !mine { Avatar(name: author.name, index: author.colorIndex) }; Text(mine ? L.t("you") : author.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text2) }
            Group {
                if placeholder {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 24, height: 24).background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.orange))
                        Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.orange)
                    }
                    .padding(.leading, 6).padding(.trailing, 14).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.14)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.orange.opacity(0.55), lineWidth: 1.2))
                } else {
                    Text(text).font(.system(size: 13)).foregroundStyle(mine ? Color.white : Color.primary).padding(.horizontal, 13).padding(.vertical, 9)
                        .background(UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: mine ? 10 : 3, bottomTrailingRadius: mine ? 3 : 10, topTrailingRadius: 10, style: .continuous).fill(mine ? Theme.accent : Theme.fill))
                }
            }
                .contentShape(Rectangle()).onTapGesture { if let a = annotation { goTo(a) } }
                .contextMenu {
                    Button(L.t("comments.delete"), role: .destructive) {
                        if let a = annotation { model.store.delete(annotation: a.id); if model.selectedAnnotation == a.id { model.selectedAnnotation = nil } }
                        else if let id = messageID { model.store.delete(message: id) }
                    }
                }
            if let chip, let a = annotation {
                HStack(spacing: 6) {
                    Button { goTo(a) } label: { Label(chip, systemImage: "clock").font(.system(size: 11, weight: .semibold).monospacedDigit()) }
                        .buttonStyle(.plain).foregroundStyle(Theme.accent).padding(.horizontal, 9).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accent.opacity(0.16)))
                    Button { model.store.delete(annotation: a.id); if model.selectedAnnotation == a.id { model.selectedAnnotation = nil } } label: { Image(systemName: "trash").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.text2).padding(.horizontal, 8).padding(.vertical, 3).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill)).help(L.t("comments.delete"))
                    Button { model.store.setStatus(a.id, a.status == .open ? .resolved : .open) } label: { Text(a.status == .open ? L.t("status.open") : L.t("status.resolved")) }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(a.status == .open ? Theme.orange : Theme.green)
                        .padding(.horizontal, 9).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill((a.status == .open ? Theme.orange : Theme.green).opacity(0.16)))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .opacity(annotation?.id == model.selectedAnnotation || model.selectedAnnotation == nil ? 1 : 0.85)
    }
}

// MARK: Feuille d'invitation

struct InviteSheet: View {
    @ObservedObject var model: AppModel
    @State private var copied = false
    func qr(_ s: String) -> NSImage {
        let f = CIFilter.qrCodeGenerator(); f.message = Data(s.utf8); f.correctionLevel = "M"
        let img = f.outputImage!.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: img); let n = NSImage(size: rep.size); n.addRepresentation(rep); return n
    }
    var body: some View {
        ZStack {
            Color.black.opacity(0.34).ignoresSafeArea().onTapGesture { close() }
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(L.t("invite.title")).font(.system(size: 19, weight: .bold)); Spacer(); if let p = model.project { StatusPill(text: p.name, color: Theme.accent) } }
                if let inv = model.invitation {
                    Picker("", selection: $model.inviteWeb) { Text(L.t("invite.browser")).tag(true); Text(L.t("invite.app")).tag(false) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 260).frame(maxWidth: .infinity, alignment: .leading).disabled(inv.webPort == nil)
                    let shown = (model.inviteWeb && inv.webPort != nil) ? inv.webLink(host: inv.host ?? "localhost") : inv.link
                    HStack(alignment: .center, spacing: 22) {
                        Image(nsImage: qr(shown)).interpolation(.none).resizable().frame(width: 132, height: 132).padding(10).background(RoundedRectangle(cornerRadius: 12).fill(.white))
                        VStack(alignment: .leading, spacing: 10) {
                            Text(L.t("invite.code")).font(.system(size: 12)).foregroundStyle(Theme.text2)
                            HStack(spacing: 8) {
                                ForEach(Array(inv.code.enumerated()), id: \.offset) { _, c in
                                    Text(String(c)).font(.system(size: 26, weight: .bold).monospacedDigit()).frame(width: 46, height: 58).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.fill))
                                }
                            }
                            HStack {
                                Text(shown).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(shown, forType: .string); copied = true } label: { Image(systemName: copied ? "checkmark" : "link").font(.system(size: 12)) }.buttonStyle(.plain)
                            }.padding(.horizontal, 14).frame(height: 38).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill))
                        }
                    }
                }
                HStack(spacing: 8) {
                    SessionCapsuleInline(model: model)
                    Spacer()
                    Button(L.t("invite.cancel")) { model.stopSession(); close() }.buttonStyle(PillButtonStyle(height: 40))
                    Button(L.t("invite.copy")) { if let i = model.invitation { let l = (model.inviteWeb && i.webPort != nil) ? i.webLink(host: i.host ?? "localhost") : i.link; NSPasteboard.general.clearContents(); NSPasteboard.general.setString(l, forType: .string); copied = true } }.buttonStyle(PillButtonStyle(prominent: true, height: 40))
                }
            }
            .padding(EdgeInsets(top: 26, leading: 28, bottom: 22, trailing: 28)).frame(width: 660).surface(radius: M.sheetRadius, floating: true)
        }
    }
    func close() { model.showInvite = false }
}

struct SessionCapsuleInline: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(model.peer != nil ? Theme.green : Theme.orange).frame(width: 8, height: 8)
            Text(model.peer.map { L.t("session.connected", $0.name) } ?? L.t("session.listening")).font(.system(size: 12.5, weight: .medium))
        }
    }
}


/// Bouton « Envoyer » du panneau Retours : rectangle arrondi vert dégradé (gris-vert discret une fois envoyé).
struct SendButtonStyle: ButtonStyle {
    var sent: Bool
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        configuration.label
            .padding(.horizontal, 13).frame(height: 28)
            .foregroundStyle(sent ? Theme.green : Color.white)
            .background(shape.fill(sent ? AnyShapeStyle(Theme.green.opacity(0.15)) : AnyShapeStyle(LinearGradient(colors: [Color(red: 0.20, green: 0.78, blue: 0.45), Color(red: 0.08, green: 0.60, blue: 0.40)], startPoint: .top, endPoint: .bottom))))
            .overlay(shape.strokeBorder(sent ? Theme.green.opacity(0.5) : Color.white.opacity(0.25), lineWidth: 1))
            .shadow(color: sent ? .clear : Color(red: 0.08, green: 0.60, blue: 0.40).opacity(0.45), radius: 4, y: 2)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
