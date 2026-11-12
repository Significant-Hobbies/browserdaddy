import AppKit
import BrowserCore
import SwiftUI
import SaaSMakerUI

struct BlockingView: View {
    @StateObject private var controller: BlockingController
    @StateObject private var protectionCheck: ProtectionCheckModel
    @State private var site = ""
    @State private var showingSchedule = false

    init(controller: BlockingController = .shared, protectionCheck: ProtectionCheckModel = ProtectionCheckModel()) {
        _controller = StateObject(wrappedValue: controller)
        _protectionCheck = StateObject(wrappedValue: protectionCheck)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                filterStatus
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 5) {
                        SMSectionHeader("Schedules", size: 30)
                        Text("Decide when a website gets your attention.").foregroundStyle(BrowserTheme.palette.mutedForeground)
                    }
                    Spacer(minLength: 16)
                    Button("Add schedule") { showingSchedule = true }
                        .buttonStyle(SMButtonStyle(.brand, size: .compact))
                        .disabled(!controller.ready || controller.busy || scheduleLimitReached)
                        .opacity(!controller.ready || controller.busy || scheduleLimitReached ? 0.4 : 1)
                        .accessibilityIdentifier("add-schedule")
                }
                if scheduleLimitReached {
                    Text("The limit of \(ScheduledSiteBlock.maximumCount) saved schedules has been reached.")
                        .font(.callout).foregroundStyle(BrowserTheme.palette.mutedForeground)
                }
                if !controller.ready {
                    SMCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(controller.loadError.isEmpty ? "Loading schedules…" : "Schedules could not load")
                                .font(.headline)
                            Text(controller.loadError.isEmpty
                                 ? "Your saved schedules will appear when loading completes."
                                 : "Saved data is preserved. Use Refresh status to retry.")
                                .foregroundStyle(BrowserTheme.palette.mutedForeground)
                        }
                    }
                } else if scheduleGroups.isEmpty {
                    SMCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("No scheduled blocks", systemImage: "calendar")
                                .font(.headline)
                            Text("Add a website and choose the hours and days to block it.")
                                .foregroundStyle(BrowserTheme.palette.mutedForeground)
                        }
                    }
                } else {
                    VStack(spacing: 16) {
                        ForEach(scheduleGroups) { group in
                            BlockingScheduleCard(group: group)
                        }
                    }
                }
                alwaysBlocked
                Label("Saved rules are locked. Ask in Codex chat to change or remove one.", systemImage: "lock")
                    .font(.callout).foregroundStyle(BrowserTheme.palette.mutedForeground)
                VStack(alignment: .leading, spacing: 16) {
                    DisclosureGroup("Check protection") { protectionCheckBand.padding(.top, 12) }
                    DisclosureGroup("Coverage, privacy & list sources") { coverageDetails.padding(.top, 12) }
                }
                .font(.callout)
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(BrowserTheme.palette.background)
        .buttonStyle(SMButtonStyle(.outline, size: .compact))
        .sheet(isPresented: $showingSchedule) { BlockingScheduleSheet(controller: controller) }
        .onAppear { protectionCheck.startObservingNetwork() }
        .onDisappear { protectionCheck.stopObservingNetwork() }
        .onChange(of: controller.configuration) { _, _ in protectionCheck.invalidate() }
        .onChange(of: controller.enabled) { _, _ in protectionCheck.invalidate() }
        .onChange(of: controller.ready) { _, _ in protectionCheck.invalidate() }
        .onChange(of: controller.busy) { _, _ in protectionCheck.invalidate() }
        .onChange(of: controller.status) { _, _ in protectionCheck.invalidate() }
        .onChange(of: controller.configuration.sites) { _, sites in
            if let host = BlockingHostname(site.trimmingCharacters(in: .whitespacesAndNewlines)), sites.contains(host) {
                site = ""
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refresh()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            protectionCheck.invalidate()
        }
    }

    private var scheduleLimitReached: Bool {
        controller.configuration.scheduledSites.count >= ScheduledSiteBlock.maximumCount
    }

    private var scheduleGroups: [BlockingScheduleGroup] {
        BlockingScheduleGroup.grouping(controller.configuration.scheduledSites)
    }

    private var filterStatus: some View {
        SMCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "shield.lefthalf.filled").foregroundStyle(BrowserTheme.palette.mutedForeground)
                    Text(controller.status).font(.callout)
                    Spacer(minLength: 8)
                    if controller.busy { ProgressView().controlSize(.small) }
                    if controller.extensionBundled {
                        Button(controller.enabled ? "Apply protected rules" : "Enable protected filter") { controller.enable() }
                            .disabled(controller.busy || !controller.ready)
                    }
                    Button("Refresh status") { controller.refresh() }.disabled(controller.busy)
                }
                if !controller.extensionBundled {
                    Text("Rules are saved locally. This build needs the signed network filter before it can block connections.")
                        .font(.caption).foregroundStyle(BrowserTheme.palette.mutedForeground)
                }
                ForEach(warnings, id: \.self) { warning in
                    Text(warning).font(.callout).foregroundStyle(BrowserTheme.palette.destructive).textSelection(.enabled)
                }
                if !controller.nativeRecoveryNote.isEmpty {
                    Text(controller.nativeRecoveryNote).font(.callout).foregroundStyle(BrowserTheme.palette.mutedForeground)
                }
            }
        }
    }

    private var warnings: [String] {
        var result: [String] = []
        for value in [controller.error, controller.loadError, controller.nativeRepairWarning] where !value.isEmpty {
            if !result.contains(value) { result.append(value) }
        }
        return result
    }

    private var alwaysBlocked: some View {
        VStack(alignment: .leading, spacing: 12) {
            SMEyebrow("Always blocked")
            SMCard {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 0) {
                        ForEach(BlockingCategory.allCases.filter { controller.configuration.categories.contains($0) }, id: \.self) { category in
                            permanentRow(category.title, detail: "All day")
                            Divider().padding(.vertical, 10)
                        }
                        ForEach(controller.configuration.sites.sorted(by: { $0.value < $1.value }), id: \.self) { host in
                            permanentRow(host.value, detail: "All day")
                                .padding(.vertical, 6)
                        }
                        if !controller.ready {
                            Text(controller.loadError.isEmpty
                                 ? "Loading saved rules…"
                                 : "Saved rules could not load. Use Refresh status to retry.")
                                .font(.callout).foregroundStyle(BrowserTheme.palette.mutedForeground)
                        }
                    }
                    Divider().padding(.vertical, 6)
                    HStack {
                        TextField("example.com", text: $site)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Always blocked website domain")
                            .onSubmit { addSite() }
                        Button("Add website") { addSite() }
                            .disabled(BlockingHostname(site.trimmingCharacters(in: .whitespacesAndNewlines)) == nil)
                    }
                    .disabled(!controller.ready || controller.busy)
                    Text("A domain rule includes its subdomains.").font(.caption).foregroundStyle(BrowserTheme.palette.mutedForeground)
                }
            }
        }
    }

    private func permanentRow(_ title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock").font(.caption).foregroundStyle(BrowserTheme.palette.mutedForeground).frame(width: 16)
            Text(title).textSelection(.enabled)
            Spacer()
            Text(detail).font(.callout).foregroundStyle(BrowserTheme.palette.mutedForeground)
        }
    }

    private var coverageDetails: some View {
        SMCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("How domain protection works").font(.headline)
                Text("The filter checks domain names supplied by macOS without inspecting page content or looking up categories online. Connections without an identifiable domain, including IP-only and local app connections, pass through. Existing connections may continue until closed.")
                Text("The filter applies to identifiable connections in regular and private windows, and other apps. It does not save visited domains, URLs or a blocked-visit log.")
                Text("Sites missing from the category lists, and adult content on shared sites, may remain accessible. Unidentified destinations are allowed so ordinary networking keeps working. Encrypted DNS, browser networking, VPNs and connection reuse can limit coverage.")
                Text("A device administrator can disable or remove the system extension through macOS or Recovery. BrowserDaddy does not change those operating-system controls.")
                Text("Cross-browser protection has not been verified on this Mac. Saved rule changes are sent to macOS when the filter is configured. Delivery and enforcement require runtime verification.")
                Divider()
                Text("Schedules follow this Mac’s local clock and time zone. Days identify the start of a window; overnight windows end the following day. After adding a rule, close and reopen existing tabs or connections so the filter can track them. Active scheduled connections are checked every second.")
                Text("macOS will ask you to approve the system extension and network filter when enabling it. If new rules cannot load, the running filter keeps its last valid rules. If it restarts without valid rules, only its built-in website rules are available until valid rules load.")
                Divider()
                Text("Bundled lists: ShadowWhisperer/BlockLists · snapshot d2f4083 · Unlicense. Both complete lists stay on this Mac and do not update automatically.")
                ForEach(BlockingCategory.allCases.filter { controller.configuration.categories.contains($0) }, id: \.self) { category in
                    Text("\(category.title): \((controller.configuration.lists[category]?.count ?? 0).formatted()) domains")
                }
            }
        }
        .foregroundStyle(BrowserTheme.secondaryInk)
    }

    private var protectionCheckBand: some View {
        SMCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Only when you click Check protection, BrowserDaddy sends one HTTPS HEAD request to each destination below. These hosts receive your IP address and standard connection metadata. No browsing history is read or sent; responses are not saved.")
                    .font(.callout).foregroundStyle(BrowserTheme.palette.mutedForeground)
                ForEach(ProtectionCheckTarget.allCases) { target in
                    HStack {
                        Text(target.rawValue).font(.callout.monospaced())
                        Text(target.isProtected ? "Protected sample" : "Allowed control")
                            .font(.caption).foregroundStyle(BrowserTheme.palette.mutedForeground)
                        Spacer()
                        Text(protectionCheck.observations[target]?.label ?? (protectionCheck.isRunning ? "Checking…" : "—"))
                            .font(.caption).foregroundStyle(BrowserTheme.palette.mutedForeground)
                    }
                }
                if controller.configuration.blocks(hostname: ProtectionCheckTarget.allowed.rawValue, outgoing: true) {
                    Text("Your rules block example.com. The allowed control will be inconclusive.")
                        .font(.callout).foregroundStyle(BrowserTheme.palette.mutedForeground)
                }
                HStack {
                    Button("Check protection") {
                        protectionCheck.start(configuration: controller.configuration, eligible: canCheckProtection)
                    }.disabled(!canCheckProtection || protectionCheck.isRunning)
                    if protectionCheck.isRunning {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { protectionCheck.cancel() }
                    }
                }
                protectionCheckResult
                Text("A failed request never proves blocking. This checks BrowserDaddy only, not Chrome, private windows, other apps or all content. Results can change as rules, connections and networks change.")
                    .font(.caption).foregroundStyle(BrowserTheme.palette.mutedForeground)
            }
        }
    }

    private var canCheckProtection: Bool {
        controller.ready && !controller.busy && controller.enabled && controller.extensionBundled
    }

    @ViewBuilder private var protectionCheckResult: some View {
        switch protectionCheck.state {
        case .idle:
            if !canCheckProtection {
                Text("Enable the bundled protected filter before checking.")
                    .font(.callout).foregroundStyle(BrowserTheme.palette.mutedForeground)
            }
        case .running:
            Text("Checking four destinations · up to 8 seconds")
                .font(.callout).foregroundStyle(BrowserTheme.palette.mutedForeground)
        case .finished(let report):
            Text(report.summary).font(.callout)
                .foregroundStyle(report.assessment == .protectedReachable ? BrowserTheme.palette.destructive : BrowserTheme.palette.mutedForeground)
            Text("Checked \(report.checkedAt.formatted(date: .abbreviated, time: .standard))")
                .font(.caption).foregroundStyle(BrowserTheme.palette.mutedForeground)
        case .cancelled:
            Text("Check cancelled. No conclusion was recorded.")
                .font(.callout).foregroundStyle(BrowserTheme.palette.mutedForeground)
        case .stale:
            Text("The previous check is stale. Run a new check for current observations.")
                .font(.callout).foregroundStyle(BrowserTheme.palette.mutedForeground)
        }
    }

    private func addSite() {
        if let host = BlockingHostname(site.trimmingCharacters(in: .whitespacesAndNewlines)), controller.configuration.sites.contains(host) {
            site = ""
        } else { _ = controller.addSite(site) }
    }
}
