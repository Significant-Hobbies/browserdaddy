import BrowserCore
import SwiftUI
import SaaSMakerUI

/// Presentation only: the saved domain value remains ScheduledSiteBlock.
struct BlockingScheduleGroup: Identifiable {
    struct Window: Hashable {
        let weekdays: Set<Int>
        let startMinute: Int
        let endMinute: Int
    }

    let window: Window
    let schedules: [ScheduledSiteBlock]
    var hosts: [String] { schedules.map(\.hostname.value) }
    var id: Window { window }
    var blockedMinutes: Int { (window.endMinute - window.startMinute + 1440) % 1440 }
    var availableMinutes: Int { 1440 - blockedMinutes }
    var continuesNextDay: Bool { window.endMinute < window.startMinute }
    var blockedIntervals: [Range<Int>] {
        if continuesNextDay {
            return [0..<window.endMinute, window.startMinute..<1440].filter { !$0.isEmpty }
        }
        return [window.startMinute..<window.endMinute]
    }
    var repeatLabel: String {
        if window.weekdays == Set(1...7) { return "Every day" }
        if window.weekdays == Set(2...6) { return "Weekdays" }
        if window.weekdays == Set([1, 7]) { return "Weekends" }
        return [2, 3, 4, 5, 6, 7, 1].filter { window.weekdays.contains($0) }
            .map { Calendar.current.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
    }
    var availableLabel: String {
        let start = window.startMinute
        let end = window.endMinute
        if continuesNextDay { return "Available \(Self.time(end))–\(Self.time(start))" }
        if start == 0 { return "Available \(Self.time(end))–midnight" }
        return "Available midnight–\(Self.time(start)) and \(Self.time(end))–midnight"
    }

    static func grouping(_ schedules: Set<ScheduledSiteBlock>) -> [Self] {
        Dictionary(grouping: schedules) {
            Window(weekdays: $0.weekdays, startMinute: $0.startMinute, endMinute: $0.endMinute)
        }.map { Self(window: $0.key, schedules: $0.value.sorted { $0.hostname.value < $1.hostname.value }) }
            .sorted {
                if $0.hosts != $1.hosts { return $0.hosts.lexicographicallyPrecedes($1.hosts) }
                if $0.window.weekdays != $1.window.weekdays {
                    return $0.window.weekdays.sorted().lexicographicallyPrecedes($1.window.weekdays.sorted())
                }
                if $0.window.startMinute != $1.window.startMinute { return $0.window.startMinute < $1.window.startMinute }
                return $0.window.endMinute < $1.window.endMinute
            }
    }

    static func time(_ minute: Int) -> String {
        if minute == 0 || minute == 1440 { return "Midnight" }
        let date = Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1,
            hour: minute / 60, minute: minute % 60))!
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func duration(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder) min" }
        if remainder == 0 { return "\(hours) \(hours == 1 ? "hour" : "hours")" }
        return "\(hours) hr \(remainder) min"
    }
}

struct BlockingScheduleDraft {
    var website = ""
    var weekdays: Set<Int> = Set(1...7)
    var start = Self.date(at: 600)
    var end = Self.date(at: 0)

    init(schedule: ScheduledSiteBlock? = nil) {
        guard let schedule else { return }
        website = schedule.hostname.value
        weekdays = schedule.weekdays
        start = Self.date(at: schedule.startMinute)
        end = Self.date(at: schedule.endMinute)
    }

    private static func date(at minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1,
            hour: minute / 60, minute: minute % 60))!
    }

    var startMinute: Int { minute(start) }
    var endMinute: Int { minute(end) }
    var schedule: ScheduledSiteBlock? {
        guard let host = BlockingHostname(website.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return ScheduledSiteBlock(hostname: host, weekdays: weekdays, startMinute: startMinute, endMinute: endMinute)
    }
    var validationMessage: String? {
        if website.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a website to continue." }
        if BlockingHostname(website.trimmingCharacters(in: .whitespacesAndNewlines)) == nil {
            return "Enter a domain such as example.com, without a path or scheme."
        }
        if weekdays.isEmpty { return "Choose at least one day." }
        if startMinute == endMinute { return "Choose different start and end times." }
        return nil
    }
    var timeExplanation: String {
        if endMinute < startMinute {
            if endMinute == 0 { return "Ends at midnight that night. Uses this Mac’s local time and time zone." }
            return "Ends the following day. Selected days start the block. Uses this Mac’s local time and time zone."
        }
        return "Starts and ends on each selected day. Uses this Mac’s local time and time zone."
    }

    private func minute(_ date: Date) -> Int {
        Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
    }
}

struct BlockingScheduleCard: View {
    let group: BlockingScheduleGroup
    let editingEnabled: Bool
    let edit: (ScheduledSiteBlock) -> Void

    var body: some View {
        SMCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "calendar")
                        .font(.title3)
                        .frame(width: 40, height: 40)
                        .background(BrowserTheme.palette.brandSoft, in: RoundedRectangle(cornerRadius: 9))
                    Text(group.hosts.joined(separator: " · "))
                        .font(.headline).textSelection(.enabled)
                    Spacer(minLength: 12)
                    editAction.disabled(!editingEnabled)
                }
                Divider().padding(.vertical, 4)
                HStack(alignment: .top, spacing: 20) {
                    scheduleValue("FROM", value: BlockingScheduleGroup.time(group.window.startMinute))
                    scheduleValue("UNTIL", value: BlockingScheduleGroup.time(group.window.endMinute))
                    scheduleValue("REPEAT", value: group.repeatLabel)
                }
                .padding(.bottom, 5)
                timeline
                HStack {
                    Text("Midnight")
                    Spacer()
                    Text("Noon")
                    Spacer()
                    Text("Midnight")
                }.font(.caption).foregroundStyle(BrowserTheme.palette.mutedForeground)
                Text("Blocked \(BlockingScheduleGroup.duration(group.blockedMinutes)) · \(group.availableLabel)")
                    .font(.callout).foregroundStyle(BrowserTheme.palette.mutedForeground)
                if group.continuesNextDay && group.window.endMinute != 0 {
                    Text("Ends the following day. The timeline shows the hours of a 24-hour clock; selected days start the block.")
                        .font(.caption).foregroundStyle(BrowserTheme.palette.mutedForeground)
                }
            }
        }
    }

    @ViewBuilder private var editAction: some View {
        if group.schedules.count == 1, let schedule = group.schedules.first {
            Button("Edit") { edit(schedule) }
                .accessibilityLabel("Edit schedule for \(schedule.hostname.value)")
        } else {
            Menu("Edit") {
                ForEach(group.schedules, id: \.self) { schedule in
                    Button(schedule.hostname.value) { edit(schedule) }
                }
            }
            .accessibilityLabel("Edit a website schedule")
        }
    }

    private func scheduleValue(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption2).tracking(1).foregroundStyle(BrowserTheme.palette.mutedForeground)
            Text(value).font(.system(size: 19, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeline: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(BrowserTheme.palette.brand.opacity(0.12))
                ForEach(group.blockedIntervals, id: \.lowerBound) { interval in
                    Rectangle().fill(BrowserTheme.palette.brand)
                        .frame(width: geometry.size.width * CGFloat(interval.count) / 1440)
                        .offset(x: geometry.size.width * CGFloat(interval.lowerBound) / 1440)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .frame(height: 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("24-hour schedule. Blocked from \(BlockingScheduleGroup.time(group.window.startMinute)) until \(BlockingScheduleGroup.time(group.window.endMinute))\(group.continuesNextDay ? " the following day" : "").")
    }
}

enum BlockingRuleSubmission<Rule: Hashable>: Equatable {
    case idle
    case saving(Rule)
    case failed(String)

    var isSaving: Bool {
        if case .saving = self { return true }
        return false
    }

    var error: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    mutating func resolve(saved: Set<Rule>, busy: Bool, error: String, replacing original: Rule? = nil) -> Bool {
        guard case .saving(let rule) = self else { return false }
        if saved.contains(rule), original.map({ !saved.contains($0) }) ?? true {
            self = .idle
            return true
        }
        if !busy { self = .failed(error.isEmpty ? "The rule was not saved. Your draft is ready to retry." : error) }
        return false
    }
}

typealias BlockingScheduleSubmission = BlockingRuleSubmission<ScheduledSiteBlock>

extension BlockingScheduleSubmission {
    func canSubmit(_ schedule: ScheduledSiteBlock?, ready: Bool, busy: Bool, saved: Set<ScheduledSiteBlock>,
                   replacing original: ScheduledSiteBlock? = nil) -> Bool {
        guard let schedule else { return false }
        let hasRoom = original.map { saved.contains($0) } ?? (saved.count < ScheduledSiteBlock.maximumCount)
        return ready && !busy && !isSaving && hasRoom && !saved.contains(schedule)
    }
}

struct BlockingScheduleSheet: View {
    @ObservedObject var controller: BlockingController
    let original: ScheduledSiteBlock?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BlockingScheduleDraft
    @State private var submission = BlockingScheduleSubmission.idle
    @FocusState private var websiteFocused: Bool

    init(controller: BlockingController, original: ScheduledSiteBlock? = nil) {
        self.controller = controller
        self.original = original
        _draft = State(initialValue: BlockingScheduleDraft(schedule: original))
    }

    private var atLimit: Bool {
        original == nil && controller.configuration.scheduledSites.count >= ScheduledSiteBlock.maximumCount
    }
    private var alreadySaved: Bool {
        guard let schedule = draft.schedule, schedule != original else { return false }
        return controller.configuration.scheduledSites.contains(schedule)
    }
    private var canSave: Bool {
        submission.canSubmit(draft.schedule, ready: controller.ready, busy: controller.busy,
                             saved: controller.configuration.scheduledSites, replacing: original)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SMSectionHeader(original == nil ? "New schedule" : "Edit schedule", size: 22)
                Spacer()
            }.padding(24)
            Divider()
            Form {
                Section {
                    TextField("Website", text: $draft.website, prompt: Text("example.com"))
                        .focused($websiteFocused)
                        .accessibilityLabel("Scheduled website domain")
                        .accessibilityIdentifier("schedule-website")
                    Text("Enter a domain. Its subdomains are included.")
                        .font(.caption).foregroundStyle(BrowserTheme.palette.mutedForeground)
                }
                Section {
                    DatePicker("Block from", selection: $draft.start, displayedComponents: .hourAndMinute)
                        .accessibilityLabel("Block from time")
                        .accessibilityIdentifier("schedule-start")
                    DatePicker("Until", selection: $draft.end, displayedComponents: .hourAndMinute)
                        .accessibilityLabel("Block until time")
                        .accessibilityIdentifier("schedule-end")
                    if draft.startMinute != draft.endMinute {
                        let minutes = (draft.endMinute - draft.startMinute + 1440) % 1440
                        Text("\(BlockingScheduleGroup.duration(minutes)) blocked · \(BlockingScheduleGroup.duration(1440 - minutes)) available per window")
                            .font(.caption).foregroundStyle(BrowserTheme.palette.mutedForeground)
                    }
                    Text(draft.timeExplanation).font(.caption).foregroundStyle(BrowserTheme.palette.mutedForeground)
                }
                Section("Repeat") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 14) {
                        ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                            Toggle(Calendar.current.weekdaySymbols[day - 1], isOn: Binding(
                                get: { draft.weekdays.contains(day) },
                                set: { if $0 { draft.weekdays.insert(day) } else { draft.weekdays.remove(day) } }))
                                .toggleStyle(.checkbox)
                                .accessibilityLabel("Repeat on \(Calendar.current.weekdaySymbols[day - 1])")
                                .accessibilityIdentifier("schedule-day-\(day)")
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    if let original, !controller.configuration.scheduledSites.contains(original) {
                        Text("This schedule changed. Reopen it to edit the latest version.")
                            .font(.callout).foregroundStyle(BrowserTheme.palette.mutedForeground)
                    } else if let message = draft.validationMessage {
                        Text(message).font(.callout).foregroundStyle(BrowserTheme.palette.mutedForeground)
                    } else if alreadySaved {
                        Text("This schedule is already saved.").font(.callout).foregroundStyle(BrowserTheme.palette.mutedForeground)
                    }
                    if atLimit {
                        Text("The limit of \(ScheduledSiteBlock.maximumCount) saved schedules has been reached.")
                            .font(.callout).foregroundStyle(BrowserTheme.palette.mutedForeground)
                    }
                    if let message = submission.error { Text(message).font(.callout).foregroundStyle(BrowserTheme.palette.destructive) }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(BrowserTheme.palette.background)
            .disabled(submission.isSaving)
            Divider()
            HStack {
                if submission.isSaving {
                    ProgressView().controlSize(.small)
                    Text("Saving schedule…").font(.callout).foregroundStyle(BrowserTheme.palette.mutedForeground)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(submission.isSaving)
                Button(original == nil ? "Add schedule" : "Save changes", action: save)
                    .buttonStyle(SMMacButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .accessibilityLabel(original == nil ? "Save new schedule" : "Save schedule changes")
                    .accessibilityIdentifier("schedule-save")
            }.padding(20)
        }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 620, idealHeight: 680)
        .background(BrowserTheme.palette.background)
        .browserTheme(BrowserTheme.palette)
        .buttonStyle(SMMacButtonStyle(.secondary))
        .interactiveDismissDisabled(submission.isSaving)
        .onAppear { websiteFocused = true }
        .onChange(of: controller.configuration.scheduledSites) { _, _ in resolveSave() }
        .onChange(of: controller.busy) { _, busy in if !busy { resolveSave() } }
    }

    private func save() {
        guard canSave, let schedule = draft.schedule else { return }
        submission = .saving(schedule)
        let accepted = original.map { controller.editScheduledSite($0, replacement: schedule) }
            ?? controller.addScheduledSite(schedule)
        if !accepted {
            submission = .failed(controller.error.isEmpty
                                 ? "The schedule could not be saved. Refresh the filter status and try again."
                                 : controller.error)
        }
    }

    private func resolveSave() {
        if submission.resolve(saved: controller.configuration.scheduledSites,
                              busy: controller.busy, error: controller.error, replacing: original) {
            dismiss()
        }
    }
}
