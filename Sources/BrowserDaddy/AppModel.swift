import Foundation
import BrowserCore
import AppKit
import CoreServices

@MainActor
final class AppModel: ObservableObject {
    @Published var report: ReportEngine.Report?
    @Published var extracting = false
    @Published private(set) var lastSuccessfulSyncAt: Date?
    @Published private(set) var lastSyncNeedsAttention = false
    @Published var extractLog: [String] = []
    @Published var automation: [String: Permissions.AutomationState] = [:]
    @Published var browserAccess: [BrowserAccessStatus] = []
    @Published var browserAccessError = ""
    struct HistoryRow: Identifiable {
        let id: String
        let time: Date?
        let browser, profile, title, url, host: String
        let category, tagSource, tagScope: String?
        let pageCategory, pageTagSource, domainCategory, domainTagSource: String?
        var source: String { "\(browser)/\(profile)" }
    }
    enum HistoryTagScope: String, CaseIterable, Identifiable {
        case page = "This page"
        case domain = "Exact domain"
        case rollup = "Whole site"
        var id: Self { self }
    }
    @Published var historyRows: [HistoryRow] = []
    @Published var browsers: [String] = []
    @Published var historySources: [String] = []
    @Published var historyCategories: [String] = []
    @Published var historyActionError: String?
    @Published var searchTerm = "" { didSet { Task { await search() } } }
    @Published var browserFilter = "all" { didSet { Task { await search() } } }
    @Published var historySourceFilter = "all" { didSet { Task { await search() } } }
    @Published var historyDaysFilter = 0 { didSet { Task { await search() } } }
    @Published var historyCategoryFilter = "all" { didSet { Task { await search() } } }
    @Published var historyTagFilter = ReportEngine.HistoryTagFilter.all {
        didSet { Task { await search() } }
    }
    @Published var launchAtLogin = false
    @Published private(set) var launchAtLoginMessage: String?
    let loginItem: DaddyLaunchAtLogin
    @Published var showAbout = false
    // attention surface
    @Published var nowApp = ""
    @Published var nowURL = ""
    @Published var focusDay = "" { didSet { loadFocusDay() } }
    @Published var focusDaysList: [String] = []
    @Published var daySegments: [ReportEngine.FocusSegRow] = []
    @Published var attentionAppsDetail: [ReportEngine.Count] = []
    @Published var attentionSitesDetail: [ReportEngine.Count] = []
    @Published var attentionHourly = [Int64](repeating: 0, count: 24)
    // analytics filters — applied across Dashboard + Attention
    @Published var filterSource = "all" { didSet { Task { await reloadFiltered() } } }
    @Published var filterDays = 0 { didSet { Task { await reloadFiltered() } } }
    /// Timeline granularity: 0 day, 1 week, 2 month.
    @Published var granularity = 0
    // onboarding + optional classification
    @Published var needsOnboarding = false
    @Published var classifyOptin = false
    @Published var classifying = false
    @Published var classifyLog: [String] = []
    @Published var classifySummary = ""
    /// SPOT CHECK: selected domain + its month-over-month verdict.
    @Published var checkHost = "www.youtube.com"
    @Published var siteCheck: ReportEngine.SiteCheck?
    // link router
    @Published var routerConfig = RouterConfig()
    /// Chromium profiles discovered inside connected browser roots.
    @Published var routerProfiles: [BrowserKind: [ChromiumProfile]] = [:]
    /// One-line feedback for the status bar (routed, picked, or failed).
    @Published var routerStatus = ""
    // tabs inventory
    struct TabGroup: Identifiable {
        var id: BrowserKind { kind }
        let kind: BrowserKind
        let state: TabSourceState
    }
    @Published var tabGroups: [TabGroup] = []
    @Published var tabsRefreshing = false
    @Published var tabSearch = ""
    @Published var tabSelection = Set<String>()
    let isPreviewFixture: Bool

    let store: ArchiveStore
    let engine: ReportEngine
    let watcher: FocusWatcher
    let alerts: AlertEngine
    let routerStore: RouterStore
    @Published var alertConfig = AlertConfig()
    private var didStartCollection = false
    private var lastExtractAt = Date.distantPast
    private var notifyWhenSyncFinishes = false
    private var classificationTask: Task<Void, Never>?
    static let classificationConsentVersion = "2"
    private let startCollectionOverride: (() -> Void)?
    private let browserGrantStore: BrowserGrantStore

    init(store suppliedStore: ArchiveStore,
         startCollection: (() -> Void)? = nil,
         previewFixture: Bool = false,
         browserGrantStore: BrowserGrantStore = BrowserGrantStore()) {
        isPreviewFixture = previewFixture
        store = suppliedStore
        engine = ReportEngine(store: store)
        watcher = FocusWatcher(store: store)
        alerts = AlertEngine(store: store)
        routerStore = RouterStore(store: store)
        alertConfig = alerts.config()
        alerts.deliver = AlertDelivery.post
        startCollectionOverride = startCollection
        self.browserGrantStore = browserGrantStore
        loginItem = DaddyLaunchAtLogin()
        launchAtLogin = loginItem.isEnabled
        launchAtLoginMessage = loginItem.message
        needsOnboarding = store.metaGet("onboarded") != "1"
        classifyOptin = store.metaGet("classify_optin") == "1"
            && store.metaGet("classify_consent_version") == Self.classificationConsentVersion
        routerConfig = routerStore.config()
        LinkRouterService.shared.model = self
        LinkRouterService.shared.drainPending()
    }

    func boot() {
        guard !needsOnboarding, !didStartCollection else { return }
        didStartCollection = true
        if let startCollectionOverride {
            startCollectionOverride()
            return
        }
        refreshPermissions()
        watcher.onTick = { [weak self] app, url in
            Task { @MainActor in
                self?.nowApp = app
                self?.nowURL = url
            }
        }
        watcher.onSegment = { [weak self] _, _ in
            Task { @MainActor in
                self?.reloadAttention()
                self?.loadFocusDay()
            }
        }
        watcher.start()
        Task.detached(priority: .utility) {
            await self.reload()
            await MainActor.run { self.reloadAttention() }
            await MainActor.run { self.loadFocusDay() }
            await self.runExtract()   // first-boot archive pass
        }
        // Archive stays fresh without launchd: re-extract while running,
        // and again when the app is activated with a stale pass.
        Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.runExtract() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.extractIfStale() }
        }
        // Attention thresholds — cheap scan of today's focus rows.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) {
            [weak self] _ in
            guard let self else { return }
            Task.detached(priority: .utility) { self.alerts.evaluate() }
        }
    }

    /// Persist alert thresholds; enabling asks macOS for notification consent.
    func setAlertConfig(_ cfg: AlertConfig) {
        let enabling = cfg.enabled && !alertConfig.enabled
        alertConfig = cfg
        alerts.saveConfig(cfg)
        if enabling { AlertDelivery.requestAuthorization() }
    }

    func refreshPermissions() {
        refreshBrowserAccess()
        Task.detached(priority: .utility) {
            var states: [String: Permissions.AutomationState] = [:]
            for (bundleID, scriptName) in FocusWatcher.tabCapableBrowsers {
                states[scriptName] = Permissions.automationState(
                    bundleID: bundleID, scriptName: scriptName)
            }
            await MainActor.run {
                self.automation = states
            }
        }
    }

    var visibleBrowserKinds: [BrowserKind] {
        let connected = Set(browserGrantStore.grants().map(\.kind))
        return BrowserKind.allCases.filter {
            connected.contains($0)
                || NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: $0.bundleIdentifier) != nil
        }
    }

    var hasConnectedBrowser: Bool {
        browserAccess.contains {
            if case .connected = $0.state { return true }
            return false
        }
    }

    func refreshBrowserAccess() {
        browserAccess = browserGrantStore.statuses(for: visibleBrowserKinds)
        refreshRouterProfiles()
    }

    // MARK: link router

    func setRouterConfig(_ cfg: RouterConfig) {
        routerConfig = cfg
        routerStore.save(cfg)
    }

    /// Chromium profile dirs for a browser — discovered under connected
    /// roots first, then user-declared, deduplicated in order.
    func profilesFor(_ kind: BrowserKind) -> [String] {
        var seen = Set<String>()
        return ((routerProfiles[kind] ?? []).map(\.directory)
                + (routerConfig.profiles[kind.rawValue] ?? []))
            .filter { seen.insert($0).inserted }
    }

    var installedBrowsers: [BrowserKind] {
        BrowserKind.allCases.filter { BrowserOpener.appURL(for: $0) != nil }
    }

    /// One row per known profile for profile-capable browsers (a plain
    /// browser row only when no profiles are known — it'd just duplicate
    /// ·Default), one row each for the rest.
    func routerTargets() -> [LinkTarget] {
        BrowserKind.allCases
            .filter { BrowserOpener.appURL(for: $0) != nil }
            .flatMap { kind -> [LinkTarget] in
                let profiles = BrowserOpener.supportsProfiles(kind)
                    ? profilesFor(kind) : []
                if profiles.isEmpty { return [LinkTarget(browser: kind)] }
                return profiles.map { LinkTarget(browser: kind, profile: $0) }
            }
    }

    /// profile dir → friendly name ("Profile 1" → "vaultwealth.com"), keyed
    /// by LinkTarget.id — picker rows show these instead of raw dirs.
    var routerProfileNames: [String: String] {
        Dictionary(uniqueKeysWithValues: routerProfiles.flatMap { kind, ps in
            ps.map { ("\(kind.rawValue)|\($0.directory)",
                      $0.name.isEmpty ? $0.directory : $0.name) }
        })
    }

    /// Clicked link while BrowserDaddy is the default browser — silent:
    /// first matching rule wins, else fallback. Never sends a link back to
    /// LaunchServices' default (that would be us — a loop).
    @discardableResult
    func route(_ url: URL) -> Bool {
        let rule = routerConfig.enabled
            ? RuleEngine.match(url, rules: routerConfig.rules) : nil
        let target = rule?.target ?? routerConfig.fallback
        if openTarget(url, target, foreground: false) {
            routerStatus = rule.map { "→ \(target.label) · \($0.pattern)" }
                ?? "→ \(target.label)"
            return true
        }
        return false
    }

    @discardableResult
    private func openTarget(_ url: URL, _ target: LinkTarget,
                            foreground: Bool) -> Bool {
        do {
            try BrowserOpener.open(url, target: target,
                                   foreground: foreground)
            return true
        } catch {
            // Fallback recovery — any installed browser, never ourselves.
            for kind in BrowserKind.allCases where kind != target.browser {
                guard BrowserOpener.appURL(for: kind) != nil else { continue }
                do {
                    try BrowserOpener.open(url, target: LinkTarget(browser: kind),
                                           foreground: foreground)
                } catch {
                    continue
                }
                let why = (error as? BrowserOpener.Failure)?.isPermissionDenied == true
                    ? "needs permission — check Privacy & Security "
                        + "in System Settings"
                    : error.localizedDescription
                routerStatus = "→ \(kind.displayName) ("
                    + "\(target.label) failed: \(why))"
                return true
            }
            routerStatus = "✗ couldn't open link — no browser found"
            return false
        }
    }

    /// ⌃⌥O — clipboard URL through the picker.
    func openClipboardLink() {
        guard let url = clipboardURL() else {
            routerStatus = "no link on the clipboard"
            return
        }
        presentPicker(url)
    }

    private func clipboardURL() -> URL? {
        guard let raw = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let url = URL(string: raw),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    // MARK: tabs inventory

    func refreshTabs() {
        guard !tabsRefreshing else { return }
        tabsRefreshing = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let raw = TabInventory.inventory()
            var groups = raw.map { TabGroup(kind: $0.kind, state: $0.state) }
            if BrowserOpener.appURL(for: .safari) != nil {
                let safari = await SafariTabsBridge.inventory()
                groups.append(TabGroup(kind: .safari, state: safari))
            }
            await MainActor.run {
                self?.tabGroups = groups
                self?.tabsRefreshing = false
            }
        }
    }

    /// Manual re-ask — the "Allow <browser>" affordance in Tabs.
    func requestTabConsent(_ kind: BrowserKind) {
        if kind == .safari {
            SafariTabsBridge.openPreferences()
            return
        }
        Task.detached { [weak self] in
            TabInventory.requestConsent(for: kind)
            await MainActor.run { self?.refreshTabs() }
        }
    }

    func closeTab(_ tab: BrowserTab) {
        if tab.browser == .safari {
            Task {
                let result = await SafariTabsBridge.operate("close", tab: tab)
                if case .failed(let message) = result { routerStatus = "✗ \(message)" }
                refreshTabs()
            }
            return
        }
        runTabOp { TabInventory.close(tab) }
    }

    func closeTabs(_ tabs: [BrowserTab]) {
        if tabs.contains(where: { $0.browser == .safari }) {
            Task {
                var failures = 0
                for tab in tabs.sorted(by: {
                    ($0.window, $0.index) > ($1.window, $1.index)
                }) {
                    let result: TabSourceState
                    if tab.browser == .safari {
                        result = await SafariTabsBridge.operate("close", tab: tab)
                    } else {
                        result = TabInventory.close(tab)
                    }
                    if case .tabs = result {} else { failures += 1 }
                }
                if failures > 0 { routerStatus = "\(failures) tab(s) could not be closed" }
                refreshTabs()
            }
            return
        }
        runTabOp {
            var last: TabSourceState = .tabs([])
            // Tabs are addressed by index — closing tab N renumbers N+1,
            // so close highest first or later closes hit the wrong tab.
            for t in tabs.sorted(by: {
                ($0.window, $0.index) > ($1.window, $1.index)
            }) {
                last = TabInventory.close(t)
            }
            return last
        }
    }

    func focusTab(_ tab: BrowserTab) {
        if tab.browser == .safari {
            Task {
                let result = await SafariTabsBridge.operate("focus", tab: tab)
                if case .failed(let message) = result { routerStatus = "✗ \(message)" }
            }
            return
        }
        runTabOp(refreshAfter: false) { TabInventory.focus(tab) }
    }

    /// DnD or "Send to" — open the URL in the target, then close the source
    /// tab only on success (never lose a tab to a failed open).
    func moveTab(_ tab: BrowserTab, to target: LinkTarget) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let url = URL(string: tab.url) else { return }
            do {
                try BrowserOpener.open(url, target: target,
                                       foreground: true)
                var sourceClosed = true
                if tab.browser == .safari {
                    let result = await SafariTabsBridge.operate("close", tab: tab)
                    if case .tabs = result {} else { sourceClosed = false }
                } else {
                    let result = TabInventory.close(tab)
                    if case .tabs = result {} else { sourceClosed = false }
                }
                await MainActor.run {
                    self?.routerStatus = sourceClosed
                        ? "→ \(target.label)"
                        : "opened in \(target.label); source tab stayed open"
                }
            } catch {
                await MainActor.run {
                    self?.routerStatus = "✗ couldn't open in \(target.label) — tab kept"
                }
            }
            await MainActor.run { self?.tabsRefreshing = false }
            await self?.refreshTabs()
        }
    }

    /// Default landing spot for drag-moves into a browser: its first
    /// router target (first known profile, else the browser itself).
    func firstTarget(for kind: BrowserKind) -> LinkTarget {
        routerTargets().first { $0.browser == kind } ?? LinkTarget(browser: kind)
    }

    var allTabs: [BrowserTab] {
        tabGroups.flatMap { group -> [BrowserTab] in
            guard case .tabs(let tabs) = group.state else { return [] }
            return tabs
        }
    }

    var filteredTabGroups: [TabGroup] {
        let q = tabSearch.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return tabGroups }
        return tabGroups.compactMap { group in
            guard case .tabs(let tabs) = group.state else { return nil }
            let kept = tabs.filter {
                $0.title.lowercased().contains(q)
                    || $0.url.lowercased().contains(q)
            }
            guard !kept.isEmpty else { return nil }
            return TabGroup(kind: group.kind, state: .tabs(kept))
        }
    }

    private func runTabOp(refreshAfter: Bool = true,
                          _ op: @escaping @Sendable () -> TabSourceState) {
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = op()
            if case .needsConsent = result {
                await MainActor.run {
                    self?.routerStatus = "needs Automation consent — approve it in System Settings"
                }
            } else if case .failed(let msg) = result {
                await MainActor.run { self?.routerStatus = "✗ \(msg)" }
            }
            if refreshAfter { await self?.refreshTabs() }
        }
    }

    /// ⌃⌥Space — frontmost browser's active tab, moved through the picker.
    /// Incognito windows return .unavailable where detectable (Chromium
    /// window-mode check); a missing `mode` in a browser's sdef fails closed.
    func moveCurrentTab() {
        switch FrontmostTab.capture() {
        case .url(_, let value):
            guard let url = URL(string: value),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                routerStatus = "no link on this tab"
                return
            }
            presentPicker(url)
        case .notBrowser(let app):
            routerStatus = "\(app) isn't a browser"
        case .needsConsent(let kind):
            routerStatus = "approve \(kind.displayName) in the "
                + "Automation prompt…"
            Task.detached { TabInventory.requestConsent(for: kind) }
        case .unavailable(let kind):
            routerStatus = "couldn't read \(kind.displayName)'s tab — "
                + "private window or nothing open"
        }
    }

    private func presentPicker(_ url: URL) {
        let rule = routerConfig.enabled
            ? RuleEngine.match(url, rules: routerConfig.rules) : nil
        LinkRouterService.shared.picker.show(
            url: url, targets: routerTargets(),
            profileNames: routerProfileNames,
            preselect: rule?.target, matchedRule: rule) { [weak self] target in
            guard let self else { return }
            // An explicit pick shows the result in the chosen browser.
            if self.openTarget(url, target, foreground: true) {
                self.routerStatus = "→ \(target.label)"
            }
        }
    }

    private func refreshRouterProfiles() {
        let grants = browserGrantStore
        Task.detached(priority: .utility) { [weak self] in
            var map: [BrowserKind: [ChromiumProfile]] = [:]
            grants.withAccessibleRoots { roots, _ in
                for root in roots where BrowserOpener.supportsProfiles(root.kind) {
                    map[root.kind] = ProfileDiscovery.chromiumProfiles(
                        userDataRoot: root.url)
                }
            }
            await MainActor.run { self?.routerProfiles = map }
        }
    }

    /// Current https handler — "com.significanthobbies.browserdaddy.dev"
    /// when we're default.
    var currentDefaultHandlerID: String {
        guard let probe = URL(string: "https://browserdaddy.invalid"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe)
        else { return "" }
        return Bundle(url: appURL)?.bundleIdentifier ?? ""
    }

    func makeDefaultBrowser() {
        guard let bid = Bundle.main.bundleIdentifier else { return }
        LSSetDefaultHandlerForURLScheme("http" as CFString, bid as CFString)
        LSSetDefaultHandlerForURLScheme("https" as CFString, bid as CFString)
        objectWillChange.send()
    }

    func connectBrowser(_ kind: BrowserKind) {
        presentConnectPanel(for: kind) { }
    }

    /// Wizard-style: panel for every detected-but-unconnected browser,
    /// back to back, each pre-opened at its data folder.
    func connectAllBrowsers() {
        let pending = visibleBrowserKinds.filter { kind in
            guard let status = browserAccess.first(where: { $0.kind == kind })
            else { return true }
            if case .connected = status.state { return false }
            return true
        }
        connectNext(pending)
    }

    private func connectNext(_ queue: [BrowserKind]) {
        guard let kind = queue.first else { return }
        presentConnectPanel(for: kind) { [weak self] in
            self?.connectNext(Array(queue.dropFirst()))
        }
    }

    private func presentConnectPanel(for kind: BrowserKind,
                                     then done: @escaping () -> Void) {
        browserAccessError = ""
        let panel = NSOpenPanel()
        panel.title = "Connect \(kind.displayName)"
        panel.message = kind.selectionHint
        panel.prompt = "Connect read-only"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        var suggestion = kind.suggestedRoot
        while !FileManager.default.fileExists(atPath: suggestion.path),
              suggestion.pathComponents.count > 2 {
            suggestion.deleteLastPathComponent()
        }
        panel.directoryURL = suggestion
        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { done() }
                guard response == .OK, let url = panel.url else { return }
                do {
                    try self.browserGrantStore.save(kind: kind, selectedURL: url)
                    self.refreshBrowserAccess()
                    self.runExtract()
                } catch {
                    self.browserAccessError = error.localizedDescription
                }
            }
        }
    }

    func removeBrowser(_ kind: BrowserKind) {
        browserGrantStore.remove(kind: kind)
        refreshBrowserAccess()
    }

    func reload() async {
        let engine = self.engine
        let src = filterSource == "all" ? nil : filterSource
        let days = filterDays
        let r = try? await Task.detached(priority: .utility) {
            try engine.build(source: src, sinceDays: days)
        }.value
        report = r
        browsers = (try? engine.browsers()) ?? []
        historySources = (try? engine.historySources()) ?? []
        historyCategories = (try? engine.historyCategories()) ?? []
        await search()
    }

    /// Filter change → rebuild report + attention stats.
    func reloadFiltered() async {
        await reload()
        reloadAttention()
    }

    /// Opt-in classification of archive domains/pages via classifier.dev.
    /// The ONLY network call this app makes; gated on user consent.
    func runClassification() {
        guard classifyOptin, !classifying else { return }
        classifying = true
        classifyLog = []
        classifySummary = ""
        let store = self.store
        classificationTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let log: @Sendable (String) -> Void = { s in
                Task { @MainActor in self.classifyLog.append(s) }
            }
            do {
                let r = try await Classifier(db: store.db).run(log: log)
                try Task.checkCancellation()
                await MainActor.run {
                    guard self.classifyOptin else { return }
                    self.classifySummary =
                        "+\(r.domains) domains, +\(r.pages) pages — "
                        + String(format: "%.0f%% of visits classified",
                                 r.coveragePct)
                }
                await self.reloadFiltered()
                await MainActor.run {
                    DaddyCompletionNotices.postIfWindowHidden(
                        title: "Classification complete",
                        body: "Open BrowserDaddy to review categorized history.")
                }
            } catch {
                if !Task.isCancelled { log("Classification failed. Please try again.") }
            }
            await MainActor.run {
                self.classifying = false
                self.classificationTask = nil
            }
        }
    }

    func setClassifyOptin(_ on: Bool) {
        classifyOptin = on
        store.metaSet("classify_optin", on ? "1" : "0")
        store.metaSet("classify_consent_version", on ? Self.classificationConsentVersion : "")
        if !on {
            classificationTask?.cancel()
            classifySummary = "Classification disabled. Previously sent data cannot be recalled."
        }
    }

    func finishOnboarding() {
        store.metaSet("onboarded", "1")
        needsOnboarding = false
        let replaying = didStartCollection
        boot()
        // On replay boot() early-returns — still extract any new grants.
        if replaying { runExtract() }
    }

    /// Re-show the first-run flow (Settings → "Review first-run setup").
    /// Collection keeps running; finishing re-persists onboarded and no-ops boot.
    func replayOnboarding() {
        needsOnboarding = true
    }

    /// Manual domain tag — persisted as source='user', survives tag runs.
    func overrideDomain(_ host: String, _ category: String) {
        try? store.setDomainCategory(host, category)
        Task { await reloadFiltered() }
    }

    /// Rollup-level tag — applies to every host under the eTLD+1.
    func overrideRollup(_ rollup: String, _ category: String) {
        try? store.setRollupCategory(rollup, category)
        Task { await reloadFiltered() }
    }

    @discardableResult
    func setHistoryTag(_ row: HistoryRow, scope: HistoryTagScope, category: String) -> Bool {
        historyActionError = nil
        do {
            switch scope {
            case .page: try store.setPageCategory(row.url, category)
            case .domain: try store.setDomainCategory(row.host, category)
            case .rollup: try store.setRollupCategory(Domain.rollup(row.host), category)
            }
            Task { await reloadFiltered() }
            return true
        } catch {
            historyActionError = "Couldn’t save this local tag. The archive was not changed."
            return false
        }
    }

    @discardableResult
    func clearHistoryTag(_ row: HistoryRow, scope: HistoryTagScope) -> Bool {
        historyActionError = nil
        do {
            switch scope {
            case .page: try store.clearPageCategory(row.url)
            case .domain: try store.clearDomainCategory(row.host)
            case .rollup: try store.clearRollupCategory(Domain.rollup(row.host))
            }
            Task { await reloadFiltered() }
            return true
        } catch {
            historyActionError = "Couldn’t clear this local tag. The archive was not changed."
            return false
        }
    }

    var historyActiveFilterCount: Int {
        [browserFilter != "all", historySourceFilter != "all", historyDaysFilter != 0,
         historyCategoryFilter != "all", historyTagFilter != .all].filter { $0 }.count
    }

    func clearHistoryFilters() {
        browserFilter = "all"
        historySourceFilter = "all"
        historyDaysFilter = 0
        historyCategoryFilter = "all"
        historyTagFilter = .all
    }

    func runSiteCheck() {
        let h = checkHost
        Task.detached(priority: .utility) { [weak self] in
            let c = try? self?.engine.siteCheck(h)
            await MainActor.run { self?.siteCheck = c }
        }
    }

    func reloadAttention() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let days = await MainActor.run { self.filterDays }
            let apps = (try? self.engine.attentionApps(sinceDays: days)) ?? []
            let sites = (try? self.engine.attentionSites(sinceDays: days)) ?? []
            let appsDetail = (try? self.engine.attentionAppsDetailed(sinceDays: days)) ?? []
            let sitesDetail = (try? self.engine.attentionSitesDetailed(sinceDays: days)) ?? []
            let hourly = (try? self.engine.attentionHourly(sinceDays: days)) ?? []
            let dayList = (try? self.engine.focusDays(sinceDays: days)) ?? []
            await MainActor.run {
                self.report?.attentionApps = apps
                self.report?.attentionSites = sites
                self.attentionAppsDetail = appsDetail
                self.attentionSitesDetail = sitesDetail
                self.attentionHourly = hourly
                self.focusDaysList = dayList
                if self.focusDay.isEmpty || !dayList.contains(self.focusDay) {
                    self.focusDay = dayList.first ?? ""
                }
            }
        }
    }

    func loadFocusDay() {
        let day = focusDay
        guard !day.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            let segs = (try? self?.engine.focusSegments(day: day)) ?? []
            await MainActor.run { self?.daySegments = segs }
        }
    }

    /// Sync on activation only when the last pass is older than the timer.
    private func extractIfStale() {
        if Date().timeIntervalSince(lastExtractAt) > 30 * 60 { runExtract() }
    }

    /// Menu-started sync can finish after the window is gone, so it may notify.
    /// Periodic background passes stay silent.
    func syncHistoryNow() {
        guard !needsOnboarding, !extracting else { return }
        notifyWhenSyncFinishes = true
        runExtract()
    }

    /// Long-running work that quitting would interrupt.
    var activeWorkDescription: String? {
        if extracting { return "History sync is still running." }
        if classifying { return "Classification is still running." }
        return nil
    }

    var menuStatus: String {
        if needsOnboarding { return "Setup needed before collection" }
        if extracting { return "Syncing local history…" }
        if classifying { return "Classifying history…" }
        if lastSyncNeedsAttention { return "Last history sync needs attention" }
        if let lastSuccessfulSyncAt {
            return "Last history sync \(lastSuccessfulSyncAt.formatted(date: .abbreviated, time: .shortened))"
        }
        return "History not synced yet"
    }

    func runExtract() {
        guard !needsOnboarding, !extracting else { return }
        extracting = true
        lastExtractAt = Date()
        extractLog = []
        let store = self.store
        let grants = browserGrantStore
        Task.detached(priority: .utility) {
            // One-time import of the Python prototype archive, if present.
            do {
                if try ArchiveImporter.importIfNeeded(into: store) {
                    Task { @MainActor in
                        self.extractLog.append(
                            "✓ imported the legacy ~/browserdaddy archive")
                    }
                }
            } catch {
                Task { @MainActor in
                    self.extractLog.append(
                        "⚠ legacy archive import failed — "
                        + error.localizedDescription)
                }
            }
            let (results, hasConnectedRoots, hasGrantFailures) = grants.withAccessibleRoots { roots, failures in
                for failure in failures {
                    Task { @MainActor in
                        self.extractLog.append("✗ \(failure.kind.displayName): \(failure.message)")
                    }
                }
                if roots.isEmpty && failures.isEmpty {
                    Task { @MainActor in
                        self.extractLog.append("No browser folders connected. Open Permissions to add one.")
                    }
                }
                let results = HistoryExtractor.run(into: store, roots: roots) { line in
                    Task { @MainActor in self.extractLog.append(line) }
                }
                return (results, !roots.isEmpty, !failures.isEmpty)
            }
            for r in results {
                if let err = r.error {
                    await MainActor.run {
                        self.extractLog.append(
                            "✗ \(r.source.browser)/\(r.source.profile): \(err)")
                    }
                }
            }
            let needsAttention = !hasConnectedRoots || hasGrantFailures || results.contains { $0.error != nil }
            await MainActor.run { self.finishExtract(needsAttention: needsAttention) }
            await MainActor.run { self.refreshBrowserAccess() }
            await self.reload()
        }
    }

    func search() async {
        let engine = self.engine
        let query = ReportEngine.HistoryQuery(
            term: searchTerm, browser: browserFilter, source: historySourceFilter,
            sinceDays: historyDaysFilter, category: historyCategoryFilter,
            tag: historyTagFilter
        )
        let rows = (try? await Task.detached(priority: .userInitiated) {
            try engine.searchHistory(query)
        }.value) ?? []
        guard query == ReportEngine.HistoryQuery(
            term: searchTerm, browser: browserFilter, source: historySourceFilter,
            sinceDays: historyDaysFilter, category: historyCategoryFilter,
            tag: historyTagFilter
        ) else { return }
        historyRows = rows.map {
            HistoryRow(
                id: "\($0.browser)/\($0.profile)/\($0.visitID)",
                time: $0.visitedAt, browser: $0.browser, profile: $0.profile,
                title: $0.title, url: $0.url, host: $0.host,
                category: $0.category, tagSource: $0.tagSource, tagScope: $0.tagScope,
                pageCategory: $0.pageCategory, pageTagSource: $0.pageTagSource,
                domainCategory: $0.domainCategory, domainTagSource: $0.domainTagSource)
        }
    }

    func finishExtract(needsAttention: Bool, at date: Date = Date()) {
        extracting = false
        lastSyncNeedsAttention = needsAttention
        if !needsAttention { lastSuccessfulSyncAt = date }
        if notifyWhenSyncFinishes {
            notifyWhenSyncFinishes = false
            DaddyCompletionNotices.postIfWindowHidden(
                title: needsAttention ? "History sync needs attention" : "History sync complete",
                body: "Open BrowserDaddy to review the archive.")
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        loginItem.set(on)
        launchAtLogin = loginItem.isEnabled
        launchAtLoginMessage = loginItem.message
    }
}
