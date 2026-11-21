// mFRAMES — réglages : apparence (clair, sombre, auto), service en arrière-plan, réseau (tout est configurable : produit distribuable).
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tab = 0
    @State private var iconMode = IconMode.current
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("authorName") private var authorName = NSFullUserName()
    @AppStorage("autoUpdate") private var autoUpdate = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                tabButton(0, "slider.horizontal.3", L.t("settings.service")); tabButton(1, "wifi", L.t("settings.network")); tabButton(2, "puzzlepiece.extension", L.t("settings.integrations"))
            }.frame(height: 78).frame(maxWidth: .infinity, alignment: .center).overlay(alignment: .bottom) { Divider() }
            ScrollView { VStack(alignment: .leading, spacing: 20) { tab == 0 ? AnyView(general) : tab == 1 ? AnyView(network) : AnyView(integrations) }.padding(EdgeInsets(top: 20, leading: 20, bottom: 22, trailing: 20)) }
        }
        .frame(width: 620, height: 580).background(Theme.chat)
    }

    func tabButton(_ i: Int, _ symbol: String, _ title: String) -> some View {
        Button { tab = i } label: {
            VStack(spacing: 3) { Image(systemName: symbol).font(.system(size: 18)); Text(title).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.85).multilineTextAlignment(.center) }
                .frame(width: 150, height: 52).foregroundStyle(tab == i ? Color.primary : Theme.text2)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tab == i ? Theme.fill2 : .clear))
        }.buttonStyle(.plain)
    }

    func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2).padding(.horizontal, 8)
            VStack(spacing: 0) { content() }.background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill))
        }
    }
    func row<C: View>(_ symbol: String, _ color: Color, _ title: String, detail: String? = nil, @ViewBuilder _ trailing: () -> C) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color))
            VStack(alignment: .leading, spacing: 1) { Text(title).font(.system(size: 13, weight: .medium)); if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Theme.text2) } }
            Spacer(minLength: 12); trailing()
        }.padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 44)
    }

    var general: some View {
        VStack(alignment: .leading, spacing: 20) {
            group(L.t("settings.appearance")) {
                row("sun.max", Color(hex: 0xff9f0a), L.t("settings.appearance")) {
                    Picker("", selection: $model.appearance) { Text(L.t("settings.light")).tag(Appearance.clair); Text(L.t("settings.dark")).tag(Appearance.sombre); Text(L.t("settings.auto")).tag(Appearance.auto) }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }
            }
            group(L.t("settings.service")) {
                row("menubar.rectangle", Color(hex: 0x30b0c7), L.t("settings.icon")) {
                    Picker("", selection: $iconMode) { ForEach(IconMode.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                        .onChange(of: iconMode) { Presence.shared.set($0) }
                }
                Text(L.t("settings.icon.help")).font(.system(size: 11)).foregroundStyle(Theme.text2).padding(.horizontal, 14).padding(.bottom, 8).frame(maxWidth: .infinity, alignment: .leading)
                Divider().padding(.leading, 54)
                row("play.fill", Color(hex: 0x0a84ff), L.t("settings.launchAtLogin")) {
                    Toggle("", isOn: $launchAtLogin).toggleStyle(.switch).labelsHidden()
                        .onChange(of: launchAtLogin) { on in if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() } }
                }
                Divider().padding(.leading, 54)
                row("person.fill", Color(hex: 0xbf5af2), L.t("settings.name")) { TextField("", text: $authorName).textFieldStyle(.roundedBorder).frame(width: 200) }
            }
            group(L.t("settings.update")) {
                row("arrow.down.circle", Color(hex: 0x30d158), L.t("settings.autoUpdate")) { Toggle("", isOn: $autoUpdate).toggleStyle(.switch).labelsHidden() }
                Divider().padding(.leading, 54)
                row("arrow.clockwise", Color(hex: 0x0a84ff), L.t("settings.updateNow")) { Button(L.t("settings.updateNow")) { UpdateEngine.shared.checkNow() }.buttonStyle(PillButtonStyle()) }
            }
        }
    }

    var integrations: some View {
        VStack(alignment: .leading, spacing: 20) {
            group(L.t("settings.integrations")) {
                row("puzzlepiece.extension", Color(hex: 0x5e5ce6), L.t("bridge.enable"), detail: L.t("bridge.enable.help")) { Toggle("", isOn: $model.bridgeEnabled).toggleStyle(.switch).labelsHidden() }
                if model.bridgeEnabled {
                    Divider().padding(.leading, 54)
                    row("key", Color(hex: 0xff9f0a), L.t("bridge.token"), detail: "127.0.0.1:\(model.bridge.port)") {
                        Button(L.t("bridge.copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.bridge.token, forType: .string) }.buttonStyle(PillButtonStyle())
                    }
                }
                Divider().padding(.leading, 54)
                row("folder", Color(hex: 0x30b0c7), L.t("bridge.modules")) {
                    Button(L.t("bridge.show")) { if let u = Bundle.main.resourceURL { NSWorkspace.shared.activateFileViewerSelecting([u.appendingPathComponent("Integrations")]) } }.buttonStyle(PillButtonStyle())
                }
            }
        }
    }

    var network: some View {
        VStack(alignment: .leading, spacing: 20) {
            group(L.t("net.mode")) {
                row("wifi", Color(hex: 0x30d158), L.t("net.mode"), detail: L.t("net.mode.help")) {
                    Picker("", selection: $model.network.mode) { ForEach(NetworkConfig.Mode.allCases, id: \.self) { Text(L.t("net.mode.\($0.rawValue)")).tag($0) } }.labelsHidden().frame(width: 220)
                }
            }
            group(L.t("net.rendezvous")) {
                row("antenna.radiowaves.left.and.right", Color(hex: 0x5e5ce6), L.t("net.rendezvous"), detail: L.t("net.rendezvous.help")) { TextField("wss://…", text: $model.network.rendezvousURL).textFieldStyle(.roundedBorder).frame(width: 230) }
                Divider().padding(.leading, 54)
                row("arrow.triangle.swap", Color(hex: 0x30b0c7), L.t("net.stun"), detail: L.t("net.stun.help")) {
                    TextField("stun:…", text: Binding(get: { model.network.stunServers.joined(separator: ", ") }, set: { model.network.stunServers = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })).textFieldStyle(.roundedBorder).frame(width: 230)
                }
                Divider().padding(.leading, 54)
                row("network", Color(hex: 0xff9f0a), L.t("net.proxy"), detail: L.t("net.proxy.help")) { TextField("", text: $model.network.proxy).textFieldStyle(.roundedBorder).frame(width: 230) }
                Divider().padding(.leading, 54)
                row("number", Color(hex: 0xff453a), L.t("net.port"), detail: L.t("net.port.help")) {
                    TextField("0", value: $model.network.listenPort, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(width: 90)
                }
                Divider().padding(.leading, 54)
                row("arrow.up.right.square", Color(hex: 0x0a84ff), L.t("net.upnp")) { Toggle("", isOn: $model.network.useUPnP).toggleStyle(.switch).labelsHidden() }
            }
            group(L.t("cache.title")) {
                row("internaldrive", Color(hex: 0x30b0c7), L.t("cache.limit"), detail: L.t("cache.limit.help")) {
                    Picker("", selection: Binding(get: { model.cacheLimitGB }, set: { model.cacheLimitGB = $0 })) { ForEach([1, 2, 5, 10, 20], id: \.self) { Text("\($0) Go").tag($0) } }.labelsHidden().frame(width: 100)
                }
                Divider().padding(.leading, 54)
                row("trash", Color(hex: 0xff453a), L.t("cache.clear.title")) { Button(L.t("cache.clear")) { model.clearLocalCopy() }.buttonStyle(PillButtonStyle()) }
            }
        }.onDisappear { model.saveNetwork() }
    }
}
