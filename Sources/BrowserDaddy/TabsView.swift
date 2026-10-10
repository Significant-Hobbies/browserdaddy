import AppKit
import BrowserCore
import Combine
import SwiftUI
import SaaSMakerUI

/// Live tab inventory. Chrome uses normal-window AppleScript; Safari's app
/// extension filters Private Browsing before it shares any tab details.
struct TabsView: View {
    @EnvironmentObject private var model: AppModel
    private let refreshTimer = Timer.publish(every: 15, on: .main,
                                             in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if model.tabGroups.isEmpty {
                emptyState
            } else if model.filteredTabGroups.isEmpty {
                ContentUnavailableView("No matching tabs",
                                       systemImage: "magnifyingglass",
                                       description: Text("Try another title or site."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tabList
            }
        }
        .background(BrowserTheme.fog)
        .onAppear { if !model.isPreviewFixture { model.refreshTabs() } }
        .onReceive(refreshTimer) { _ in
            if !model.isPreviewFixture { model.refreshTabs() }
        }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                toolbarTitle
                Spacer(minLength: 16)
                toolbarControls
            }
            VStack(alignment: .leading, spacing: 10) {
                toolbarTitle
                toolbarControls
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var toolbarTitle: some View {
        VStack(alignment: .leading, spacing: 2) {
            SMSectionHeader("Open tabs", size: 22)
            Text(tabSummary)
                .font(.caption)
                .foregroundStyle(BrowserTheme.secondaryInk)
        }
    }

    private var tabSummary: String {
        let total = model.allTabs.count
        guard total > 0 else { return "No regular tabs shared yet" }
        let browserCount = Set(model.allTabs.map(\.browser)).count
        let sourceLabel = browserCount > 1 ? "across browsers" :
            (model.allTabs.first?.browser.displayName ?? "browser")
        guard !model.tabSearch.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "\(total.formatted()) " + (total == 1 ? "tab" : "tabs")
                + " \(sourceLabel)"
        }
        let visible = model.filteredTabGroups.reduce(0) { count, group in
            guard case .tabs(let tabs) = group.state else { return count }
            return count + tabs.count
        }
        return "\(visible.formatted()) of \(total.formatted()) tabs shown"
    }

    private var toolbarControls: some View {
        HStack(spacing: 10) {
            TextField("Search title or site", text: $model.tabSearch)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, maxWidth: 240)
                .accessibilityLabel("Search open tabs")
            if !model.tabSearch.isEmpty {
                Button { model.tabSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(BrowserTheme.secondaryInk)
                .help("Clear search")
                .accessibilityLabel("Clear tab search")
            }
            if !model.tabSelection.isEmpty {
                Button("Focus") { focusSelected() }.textCase(.lowercase)
                Button("Close \(model.tabSelection.count) tabs") {
                    let ids = model.tabSelection
                    model.closeTabs(model.allTabs.filter { ids.contains($0.id) })
                    model.tabSelection = []
                }
                .textCase(.lowercase)
                .buttonStyle(DaddyButtonStyle(prominent: true))
            }
            if model.tabsRefreshing {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Refreshing tabs")
            }
            Button { model.refreshTabs() } label: {
                Label("Refresh", systemImage: "arrow.clockwise").textCase(.lowercase)
            }
            .disabled(model.tabsRefreshing || model.isPreviewFixture)
        }
    }

    private var emptyState: some View {
        Group {
            if model.tabsRefreshing {
                ProgressView("Reading open tabs…")
            } else {
                ContentUnavailableView("No browsers available",
                                       systemImage: "macwindow.on.rectangle",
                                       description: Text("Open Chrome or Safari to see tabs."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(BrowserTheme.secondaryInk)
    }

    private var tabList: some View {
        List(selection: $model.tabSelection) {
            ForEach(model.filteredTabGroups) { group in
                Section {
                    switch group.state {
                    case .tabs(let tabs):
                        ForEach(tabs) { tab in
                            tabRow(tab)
                        }
                    case .notRunning:
                        stateNote("browser is closed")
                    case .noWindows:
                        stateNote(group.kind == .safari
                                  ? "no regular tabs shared — check Safari website access"
                                  : "no open windows")
                    case .needsConsent:
                        HStack(spacing: 8) {
                            Text(group.kind == .safari
                                 ? "Enable BrowserDaddy Safari Tabs in Safari Settings — "
                                 : "needs Automation permission — ")
                            Button(group.kind == .safari
                                   ? "Open Safari Extensions"
                                   : "Allow \(group.kind.displayName)") {
                                model.requestTabConsent(group.kind)
                            }
                            .buttonStyle(.link)
                            if group.kind != .safari {
                                Text("·")
                                Button("Open Settings") {
                                    NSWorkspace.shared.open(URL(string:
                                        "x-apple.systempreferences:"
                                        + "com.apple.preference.security"
                                        + "?Privacy_Automation")!)
                                }.textCase(.lowercase)
                                .buttonStyle(.link)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(BrowserTheme.secondaryInk.opacity(0.7))
                        .padding(.vertical, 4)
                    case .unsupported:
                        stateNote("not scriptable — tabs can't be listed")
                    case .failed(let msg):
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(BrowserTheme.amber)
                            Text("Couldn’t read tabs")
                                .foregroundStyle(BrowserTheme.ink)
                            Text(msg).lineLimit(1)
                                .foregroundStyle(BrowserTheme.secondaryInk)
                                .help(msg)
                            Spacer()
                            Button("Retry") { model.refreshTabs() }.textCase(.lowercase)
                                .disabled(model.tabsRefreshing)
                        }
                        .font(.caption)
                        .padding(.vertical, 6)
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text(group.kind.displayName)
                            .font(.headline)
                            .foregroundStyle(BrowserTheme.secondaryInk)
                        if case .tabs(let tabs) = group.state {
                            Text("\(tabs.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(BrowserTheme.mintInk)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .help("Drop a tab here to move it to \(group.kind.displayName)")
                    .dropDestination(for: BrowserTab.self) { items, _ in
                        guard let tab = items.first,
                              tab.browser != group.kind else { return false }
                        model.moveTab(tab, to: model.firstTarget(for: group.kind))
                        return true
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func tabRow(_ tab: BrowserTab) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title.isEmpty ? tab.url : tab.title)
                    .font(.callout)
                    .foregroundStyle(BrowserTheme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text(tab.host)
                    .font(.caption.monospaced())
                    .foregroundStyle(BrowserTheme.secondaryInk)
                    .lineLimit(1)
            }
            Spacer()
            Text("Window \(tab.window)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(BrowserTheme.secondaryInk.opacity(0.6))
            Button { model.closeTab(tab) } label: {
                Image(systemName: "xmark.circle")
                    .font(.callout)
                    .foregroundStyle(BrowserTheme.secondaryInk)
            }
            .buttonStyle(.plain)
            .help("Close tab")
            .accessibilityLabel("Close \(tab.title.isEmpty ? tab.host : tab.title)")
        }
        .padding(.vertical, 2)
        .draggable(tab)
        .onTapGesture(count: 2) { model.focusTab(tab) }
        .contextMenu {
            Button("Focus tab") { model.focusTab(tab) }.textCase(.lowercase)
            Button("Close tab") { model.closeTab(tab) }.textCase(.lowercase)
            Divider()
            Menu("Send to") {
                ForEach(model.routerTargets().filter {
                    $0.browser != tab.browser
                }) { target in
                    Button(targetLabel(target)) {
                        model.moveTab(tab, to: target)
                    }
                }
            }
            Divider()
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tab.url, forType: .string)
            }.textCase(.lowercase)
        }
        .tag(tab.id)
    }

    private func targetLabel(_ target: LinkTarget) -> String {
        guard !target.profile.isEmpty else { return target.browser.displayName }
        let name = model.routerProfileNames[target.id]
        let shown = name.map { $0 == target.profile ? $0
            : "\($0) (\(target.profile))" } ?? target.profile
        return "\(target.browser.displayName) · \(shown)"
    }

    private func stateNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(BrowserTheme.secondaryInk.opacity(0.7))
            .padding(.vertical, 4)
    }

    private func focusSelected() {
        guard let first = model.allTabs.first(where: {
            model.tabSelection.contains($0.id)
        }) else { return }
        model.focusTab(first)
    }
}
