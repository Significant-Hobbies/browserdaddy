import AppKit
import BrowserCore
import SwiftUI

/// Link-routing workspace: default-browser interception, per-URL rules,
/// fallback target, profiles, and the explicit picker actions.
struct RouterView: View {
    @EnvironmentObject private var model: AppModel
    @State private var defaultHandlerID = ""
    @State private var draftPattern = ""
    @State private var manualProfile: [BrowserKind: String] = [:]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                routeBand
                rulesBand
                fallbackBand
                targetsBand
                actionsBand
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .background(BrowserTheme.fog)
        .onAppear { defaultHandlerID = model.currentDefaultHandlerID }
    }

    // MARK: bands

    private var routeBand: some View {
        BrowserBand(label: "ROUTE",
                    subtitle: "Intercept links clicked anywhere on this Mac") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Route links through BrowserDaddy", isOn: Binding(
                    get: { model.routerConfig.enabled },
                    set: { var c = model.routerConfig; c.enabled = $0
                           model.setRouterConfig(c) }))
                    .tint(BrowserTheme.mintInk)
                    .foregroundStyle(BrowserTheme.ink)
                HStack(spacing: 12) {
                    Text("Default browser")
                        .font(.callout).foregroundStyle(BrowserTheme.ink)
                    Text(defaultHandlerLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(BrowserTheme.secondaryInk)
                    Spacer()
                    if !isDefault {
                        Button("Make BrowserDaddy default") {
                            model.makeDefaultBrowser()
                            defaultHandlerID = model.currentDefaultHandlerID
                        }.textCase(.lowercase)
                        .buttonStyle(DaddyButtonStyle(prominent: true))
                    }
                }
                Text(isDefault
                     ? "Clicked links arrive here silently — first rule match wins, everything else goes to the fallback."
                     : "Set BrowserDaddy as the default browser to route clicked links. Or System Settings → Desktop & Dock → Default web browser.")
                    .font(.caption)
                    .foregroundStyle(BrowserTheme.secondaryInk)
            }
        }
    }

    private var rulesBand: some View {
        BrowserBand(label: "RULES",
                    subtitle: "First match wins — host name, * glob, or *path* patterns") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.routerConfig.rules) { rule in
                    ruleRow(rule)
                }
                HStack(spacing: 10) {
                    TextField("pattern — github.com, *.corp.dev, *meet*", text: $draftPattern)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                    Button("Add rule") {
                        let p = draftPattern.trimmingCharacters(in: .whitespaces)
                        guard !p.isEmpty else { return }
                        var cfg = model.routerConfig
                        cfg.rules.append(RouteRule(
                            pattern: p.lowercased(),
                            target: cfg.fallback))
                        model.setRouterConfig(cfg)
                        draftPattern = ""
                    }.textCase(.lowercase)
                    .disabled(draftPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if model.routerConfig.rules.isEmpty {
                    Text("No rules yet — unmatched links go to the fallback. "
                         + "A bare domain also covers its subdomains.")
                        .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                }
            }
        }
    }

    private func ruleRow(_ rule: RouteRule) -> some View {
        HStack(spacing: 10) {
            VStack(spacing: 2) {
                Button { moveRule(rule, by: -1) } label: {
                    Image(systemName: "chevron.up")
                }
                Button { moveRule(rule, by: 1) } label: {
                    Image(systemName: "chevron.down")
                }
            }
            .buttonStyle(.plain)
            .font(.caption2)
            .foregroundStyle(BrowserTheme.secondaryInk)

            Text(rule.pattern)
                .font(.callout.monospaced())
                .foregroundStyle(BrowserTheme.ink)
                .frame(minWidth: 160, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
            browserMenu(selection: Binding(
                get: { binding(for: rule).target.browser.wrappedValue },
                set: { kind in
                    var r = binding(for: rule).wrappedValue
                    r.target.browser = kind
                    if !BrowserOpener.supportsProfiles(kind) { r.target.profile = "" }
                    binding(for: rule).wrappedValue = r
                }))
            if BrowserOpener.supportsProfiles(binding(for: rule).target.browser.wrappedValue) {
                profileMenu(kind: binding(for: rule).target.browser.wrappedValue,
                            selection: binding(for: rule).target.profile)
            }
            Spacer()
            Button("Remove") {
                var cfg = model.routerConfig
                cfg.rules.removeAll { $0.id == rule.id }
                model.setRouterConfig(cfg)
            }.textCase(.lowercase)
        }
    }

    private var fallbackBand: some View {
        BrowserBand(label: "FALLBACK",
                    subtitle: "Where unmatched — or all, when routing is off — links open") {
            HStack(spacing: 10) {
                browserMenu(selection: Binding(
                    get: { model.routerConfig.fallback.browser },
                    set: { var c = model.routerConfig
                           c.fallback.browser = $0
                           if !BrowserOpener.supportsProfiles($0) {
                               c.fallback.profile = ""
                           }
                           model.setRouterConfig(c) }))
                if BrowserOpener.supportsProfiles(model.routerConfig.fallback.browser) {
                    profileMenu(kind: model.routerConfig.fallback.browser,
                                selection: Binding(
                        get: { model.routerConfig.fallback.profile },
                        set: { var c = model.routerConfig
                               c.fallback.profile = $0
                               model.setRouterConfig(c) }))
                }
            }
        }
    }

    private var targetsBand: some View {
        BrowserBand(label: "PROFILES",
                    subtitle: "Chromium profile dirs — discovered under connected folders, or added here") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.installedBrowsers) { kind in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(kind.displayName)
                            .font(.callout).foregroundStyle(BrowserTheme.ink)
                            .frame(minWidth: 120, alignment: .leading)
                        if BrowserOpener.supportsProfiles(kind) {
                            let known = model.profilesFor(kind)
                            Text(known.isEmpty ? "default profile only"
                                               : known.joined(separator: " · "))
                                .font(.caption.monospaced())
                                .foregroundStyle(BrowserTheme.secondaryInk)
                                .lineLimit(1)
                            Spacer()
                            TextField("add profile dir",
                                      text: manualProfileBinding(kind))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 130)
                                .onSubmit { addManualProfile(kind) }
                            Button("Add") { addManualProfile(kind) }.textCase(.lowercase)
                                .disabled((manualProfile[kind] ?? "")
                                    .trimmingCharacters(in: .whitespaces).isEmpty)
                        } else {
                            Text("no profile targeting")
                                .font(.caption)
                                .foregroundStyle(BrowserTheme.secondaryInk)
                            Spacer()
                        }
                    }
                }
                Text("Profile dirs come from the browser's own folder "
                     + "(Default, Profile 1, …). Connect a browser's data "
                     + "folder in Permissions to discover names — Safari "
                     + "can't be profile-targeted at all.")
                    .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
            }
        }
    }

    private var actionsBand: some View {
        BrowserBand(label: "ACTIONS",
                    subtitle: "Explicit picks — the floating target chooser") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Nothing reacts to copying on its own — the picker "
                     + "only appears when you ask for it.")
                    .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                HStack(spacing: 12) {
                    Button("Open clipboard link") { model.openClipboardLink() }.textCase(.lowercase)
                    Button("Move current tab here") { model.moveCurrentTab() }.textCase(.lowercase)
                }
                Text("\(LinkRouterService.clipboardKey.name) — open the "
                     + "copied link in a browser you pick\n"
                     + "\(LinkRouterService.moveTabKey.name) — take the "
                     + "frontmost browser's current tab elsewhere\n"
                     + "In the picker: ↑↓ choose, ⏎ open, 1–9 jump, esc cancel")
                    .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                Text("The current-tab hotkey reads normal Chrome "
                     + "windows after Automation consent. Safari tabs are "
                     + "managed from Tabs after enabling its extension.")
                    .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
            }
        }
    }

    // MARK: controls

    private func browserMenu(selection: Binding<BrowserKind>) -> some View {
        Menu {
            ForEach(model.installedBrowsers) { kind in
                Button(kind.displayName) { selection.wrappedValue = kind }
            }
        } label: {
            Label(selection.wrappedValue.displayName,
                  systemImage: "chevron.up.chevron.down")
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(BrowserTheme.mintInk.opacity(0.4), lineWidth: 1))
    }

    private func profileMenu(kind: BrowserKind,
                             selection: Binding<String>) -> some View {
        Menu {
            Button("default profile") { selection.wrappedValue = "" }
            ForEach(model.profilesFor(kind), id: \.self) { dir in
                Button(profileLabel(kind, dir)) { selection.wrappedValue = dir }
            }
        } label: {
            Label(selection.wrappedValue.isEmpty
                  ? "default profile"
                  : profileLabel(kind, selection.wrappedValue),
                  systemImage: "person.crop.circle")
                .font(.callout)
                .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(BrowserTheme.mintInk.opacity(0.4), lineWidth: 1))
    }

    private func profileLabel(_ kind: BrowserKind, _ dir: String) -> String {
        if let found = model.routerProfiles[kind]?
            .first(where: { $0.directory == dir }), !found.name.isEmpty {
            return "\(found.name) (\(dir))"
        }
        return dir
    }

    // MARK: helpers

    private var isDefault: Bool {
        defaultHandlerID == Bundle.main.bundleIdentifier
    }

    private var defaultHandlerLabel: String {
        guard !defaultHandlerID.isEmpty else { return "unknown" }
        if isDefault { return "BrowserDaddy" }
        if let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: defaultHandlerID) {
            return FileManager.default
                .displayName(atPath: url.deletingPathExtension().lastPathComponent)
        }
        return defaultHandlerID
    }

    private func binding(for rule: RouteRule) -> Binding<RouteRule> {
        Binding(
            get: { model.routerConfig.rules.first { $0.id == rule.id } ?? rule },
            set: { updated in
                var cfg = model.routerConfig
                if let i = cfg.rules.firstIndex(where: { $0.id == updated.id }) {
                    cfg.rules[i] = updated
                    model.setRouterConfig(cfg)
                }
            })
    }

    private func moveRule(_ rule: RouteRule, by offset: Int) {
        var cfg = model.routerConfig
        guard let i = cfg.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        let j = i + offset
        guard cfg.rules.indices.contains(j) else { return }
        cfg.rules.swapAt(i, j)
        model.setRouterConfig(cfg)
    }

    private func manualProfileBinding(_ kind: BrowserKind) -> Binding<String> {
        Binding(get: { manualProfile[kind] ?? "" },
                set: { manualProfile[kind] = $0 })
    }

    private func addManualProfile(_ kind: BrowserKind) {
        let dir = (manualProfile[kind] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else { return }
        var cfg = model.routerConfig
        var list = cfg.profiles[kind.rawValue] ?? []
        if !list.contains(dir) {
            list.append(dir)
            cfg.profiles[kind.rawValue] = list
            model.setRouterConfig(cfg)
        }
        manualProfile[kind] = ""
    }
}
