import AppKit
import BrowserCore
import SwiftUI

struct BlockingView: View {
    @StateObject private var controller: BlockingController
    @StateObject private var protectionCheck: ProtectionCheckModel
    @State private var site = ""
    @State private var scheduledSite = ""
    @State private var scheduledDays: Set<Int> = Set(1...7)
    @State private var scheduleStart = Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: 10))!
    @State private var scheduleEnd = Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: 0))!

    init(controller: BlockingController = .shared, protectionCheck: ProtectionCheckModel = ProtectionCheckModel()) {
        _controller = StateObject(wrappedValue: controller)
        _protectionCheck = StateObject(wrappedValue: protectionCheck)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                BrowserBand(label: "BLOCKING", subtitle: "One set of rules, including private windows") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(controller.status, systemImage: controller.enabled ? "shield.lefthalf.filled" : "shield")
                            .font(.headline)
                        if controller.extensionBundled {
                            HStack {
                                Button(controller.enabled ? "Apply protected rules" : "Enable protected filter") {
                                    controller.enable()
                                }.disabled(controller.busy || !controller.ready)
                                Button("Refresh status") { controller.refresh() }.disabled(controller.busy)
                            }
                        }
                        Text(controller.extensionBundled
                             ? "macOS will ask you to approve the system extension and network filter. Protection is committed in this app. You can add blocked websites; changes to protected settings require deliberate maintenance requested through Codex chat. If new rules cannot load, the running filter keeps its last valid rules. On first start, only the built-in website rules are available until valid rules load."
                             : "Your rules are saved locally. This build needs the signed BrowserDaddy network-filter extension before it can block connections.")
                            .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                        if !controller.error.isEmpty {
                            Text(controller.error).font(.callout).foregroundStyle(BrowserTheme.coral)
                        }
                        if !controller.loadError.isEmpty && controller.loadError != controller.error {
                            Text(controller.loadError).font(.callout).foregroundStyle(BrowserTheme.coral)
                        }
                        if !controller.nativeRepairWarning.isEmpty && controller.nativeRepairWarning != controller.error {
                            Text(controller.nativeRepairWarning).font(.callout).foregroundStyle(BrowserTheme.coral)
                        }
                        if !controller.nativeRecoveryNote.isEmpty {
                            Text(controller.nativeRecoveryNote).font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                        }
                    }
                }
                protectionCheckBand
                BrowserBand(label: "CATEGORIES", subtitle: "Block known domains using offline lists") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(BlockingCategory.allCases, id: \.self) { category in
                            HStack {
                                Label(category.title, systemImage: "checkmark.shield.fill")
                                Spacer()
                                Text("\((controller.configuration.lists[category]?.count ?? 0).formatted()) domains")
                                    .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                            }
                        }
                        Text("Bundled lists: ShadowWhisperer/BlockLists · bundled snapshot d2f4083 · Unlicense. Both complete lists are protected, stay on this Mac and do not update automatically.")
                            .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                    }
                }
                .disabled(!controller.ready || controller.busy)
                BrowserBand(label: "DOMAIN PROTECTION", subtitle: "Local rules · normal networking stays available") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Connections to identified blocked domains are stopped", systemImage: "checkmark.shield.fill")
                        Text("The filter checks domain names supplied by macOS without inspecting page content or looking up categories online. Connections without an identifiable domain, including IP-only and local app connections, pass through. Protected settings require assisted maintenance through Codex chat. Existing connections may continue until closed.")
                            .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                    }
                }.disabled(!controller.ready || controller.busy)
                BrowserBand(label: "SITES", subtitle: "A domain rule also blocks its subdomains") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField("example.com", text: $site).textFieldStyle(.roundedBorder)
                                .onSubmit { addSite() }
                            Button("Add website") { addSite() }.disabled(site.isEmpty)
                        }
                        ForEach(controller.configuration.sites.sorted(by: { $0.value < $1.value }), id: \.self) { host in
                            HStack {
                                Text(host.value).font(.callout.monospaced())
                                Spacer()
                            }
                        }
                        if controller.configuration.sites.isEmpty {
                            Text("Add any other websites you want blocked.")
                                .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                        }
                    }
                }
                .disabled(!controller.ready || controller.busy)
                scheduledBlocksBand
                BrowserBand(label: "COVERAGE & PRIVACY", subtitle: "Rules are not a guarantee of complete protection") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("The filter applies to identifiable connections in regular and private windows, and other apps. It does not save visited domains, URLs or a blocked-visit log.")
                        Text("Sites missing from the category lists, and adult content on shared sites, may remain accessible. Unidentified destinations are allowed so ordinary networking keeps working. Encrypted DNS, browser networking, VPNs and connection reuse can limit coverage.")
                        Text("A device administrator can disable or remove the system extension through macOS or Recovery. BrowserDaddy does not change those operating-system controls.")
                        Text("Cross-browser protection has not been verified on this Mac. Saved rule changes are sent to macOS when the filter is configured. Delivery and enforcement require runtime verification; existing connections may continue until closed.")
                    }.font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(BrowserTheme.fog)
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

    private var scheduleDraft: ScheduledSiteBlock? {
        guard let host = BlockingHostname(scheduledSite.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let calendar = Calendar.current
        return ScheduledSiteBlock(hostname: host, weekdays: scheduledDays,
            startMinute: calendar.component(.hour, from: scheduleStart) * 60 + calendar.component(.minute, from: scheduleStart),
            endMinute: calendar.component(.hour, from: scheduleEnd) * 60 + calendar.component(.minute, from: scheduleEnd))
    }

    private var sortedSchedules: [ScheduledSiteBlock] {
        controller.configuration.scheduledSites.sorted {
            if $0.hostname.value != $1.hostname.value { return $0.hostname.value < $1.hostname.value }
            if $0.weekdays != $1.weekdays { return $0.weekdays.sorted().lexicographicallyPrecedes($1.weekdays.sorted()) }
            if $0.startMinute != $1.startMinute { return $0.startMinute < $1.startMinute }
            return $0.endMinute < $1.endMinute
        }
    }

    private var scheduledBlocksBand: some View {
        BrowserBand(label: "SCHEDULED BLOCKS", subtitle: "Other websites · this Mac’s local time") {
            VStack(alignment: .leading, spacing: 12) {
                TextField("example.com", text: $scheduledSite).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Scheduled website domain")
                HStack(spacing: 8) {
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                        Toggle(Calendar.current.shortWeekdaySymbols[day - 1], isOn: Binding(
                            get: { scheduledDays.contains(day) },
                            set: { if $0 { scheduledDays.insert(day) } else { scheduledDays.remove(day) } }))
                            .toggleStyle(.button)
                            .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                    }
                }
                HStack {
                    DatePicker("From", selection: $scheduleStart, displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: $scheduleEnd, displayedComponents: .hourAndMinute)
                    Button("Add schedule") {
                        if let schedule = scheduleDraft { _ = controller.addScheduledSite(schedule) }
                    }.disabled(scheduleDraft == nil || controller.configuration.scheduledSites.count >= ScheduledSiteBlock.maximumCount)
                }
                if let draft = scheduleDraft, draft.endMinute < draft.startMinute {
                    Text("Ends the following day").font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                }
                Text("Choose days and different start and end times. An end before the start continues into the next day. Includes subdomains; follows this Mac’s clock and time zone.")
                    .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                ForEach(sortedSchedules, id: \.self) { schedule in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(schedule.hostname.value).font(.callout.monospaced())
                        Text(scheduleDescription(schedule)).font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                    }
                }
                if controller.configuration.scheduledSites.isEmpty {
                    Text("No scheduled blocks added.").font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                }
                Text("Protected categories, YouTube, Reddit and Instagram stay blocked at all times. Added schedules require assisted maintenance to change. After adding one, close and reopen existing tabs or connections so the filter can track them; active scheduled connections are checked every second. No visit log is saved.")
                    .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
            }
        }
        .disabled(!controller.ready || controller.busy)
        .onChange(of: controller.configuration.scheduledSites) { _, schedules in
            if let draft = scheduleDraft, schedules.contains(draft) {
                scheduledSite = ""
            }
        }
    }

    private func scheduleDescription(_ schedule: ScheduledSiteBlock) -> String {
        let days = [2, 3, 4, 5, 6, 7, 1].filter { schedule.weekdays.contains($0) }
            .map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
        func time(_ minute: Int) -> String {
            let date = Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: minute / 60, minute: minute % 60))!
            return date.formatted(date: .omitted, time: .shortened)
        }
        return "\(days) · \(time(schedule.startMinute))–\(time(schedule.endMinute))\(schedule.endMinute < schedule.startMinute ? " next day" : "") · local time"
    }

    private var protectionCheckBand: some View {
        BrowserBand(label: "CHECK PROTECTION", subtitle: "Four samples from this app's network path") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Only when you click Check protection, BrowserDaddy sends one HTTPS HEAD request to each destination below. These hosts receive your IP address and standard connection metadata. No browsing history is read or sent; responses are not saved.")
                    .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
                ForEach(ProtectionCheckTarget.allCases) { target in
                    HStack {
                        Text(target.rawValue).font(.callout.monospaced())
                        Text(target.isProtected ? "Protected sample" : "Allowed control")
                            .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                        Spacer()
                        Text(protectionCheck.observations[target]?.label ?? (protectionCheck.isRunning ? "Checking…" : "—"))
                            .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
                    }
                }
                if controller.configuration.blocks(hostname: ProtectionCheckTarget.allowed.rawValue, outgoing: true) {
                    Text("Your rules block example.com. The allowed control will be inconclusive.")
                        .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
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
                    .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
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
                    .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
            }
        case .running:
            Text("Checking four destinations · up to 8 seconds")
                .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
        case .finished(let report):
            Text(report.summary).font(.callout)
                .foregroundStyle(report.assessment == .protectedReachable ? BrowserTheme.coral : BrowserTheme.secondaryInk)
            Text("Checked \(report.checkedAt.formatted(date: .abbreviated, time: .standard))")
                .font(.caption).foregroundStyle(BrowserTheme.secondaryInk)
        case .cancelled:
            Text("Check cancelled. No conclusion was recorded.")
                .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
        case .stale:
            Text("The previous check is stale. Run a new check for current observations.")
                .font(.callout).foregroundStyle(BrowserTheme.secondaryInk)
        }
    }

    private func addSite() {
        if let host = BlockingHostname(site.trimmingCharacters(in: .whitespacesAndNewlines)), controller.configuration.sites.contains(host) {
            site = ""
        } else { _ = controller.addSite(site) }
    }
}
