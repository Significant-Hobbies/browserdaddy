import AppKit
import Foundation

/// Resolve a GUI process once; bundle identifiers do not distinguish automation instances.
enum BrowserProcess {
    struct Candidate: Equatable {
        let pid: pid_t
        let regular: Bool
    }

    enum Failure: Error { case notRunning, ambiguous }

    static func select(_ candidates: [Candidate], frontmost: pid_t?) throws -> pid_t {
        let gui = candidates.filter(\.regular)
        if let frontmost, gui.contains(where: { $0.pid == frontmost }) { return frontmost }
        guard !gui.isEmpty else { throw Failure.notRunning }
        guard gui.count == 1 else { throw Failure.ambiguous }
        return gui[0].pid
    }

    static func application(bundleID: String) throws -> NSRunningApplication {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
        let pid = try select(applications.map {
            Candidate(pid: $0.processIdentifier, regular: $0.activationPolicy == .regular)
        }, frontmost: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        guard let app = applications.first(where: { $0.processIdentifier == pid }) else {
            throw Failure.notRunning
        }
        return app
    }

    static func permitsUnboundAction(bundleID: String) -> Bool {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
        return permitsUnboundAction(applications.map {
            Candidate(pid: $0.processIdentifier, regular: $0.activationPolicy == .regular)
        })
    }

    static func permitsUnboundAction(_ candidates: [Candidate]) -> Bool {
        candidates.count == 1 && candidates[0].regular
    }
}

/// Only get-data events are sent. Window identity is pinned before checking its
/// immutable mode, so a reordered private window cannot replace an approved one.
struct ChromiumCapture {
    enum Failure: Error, Equatable {
        case needsConsent, unavailable
    }

    struct ActiveTabMetadata: Equatable {
        let windowID: String
        let mode: String
        let activeTabID: String?
    }

    private struct ActiveTabTarget {
        let metadata: ActiveTabMetadata
        let window: NSAppleEventDescriptor
        let tabID: NSAppleEventDescriptor?
    }

    static let supportedBundleIDs: Set<String> = [
        "com.google.Chrome", "com.brave.Browser", "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi", "company.thebrowser.Browser",
        "com.operasoftware.Opera", "org.chromium.Chromium",
    ]

    typealias Send = (NSAppleEventDescriptor, NSAppleEventDescriptor.SendOptions) throws
        -> NSAppleEventDescriptor

    let address: NSAppleEventDescriptor
    private let send: Send
    static var sendOptions: NSAppleEventDescriptor.SendOptions {
        [.waitForReply, .neverInteract,
         NSAppleEventDescriptor.SendOptions(rawValue: UInt(kAEDoNotPromptForUserConsent))]
    }

    init(processID: pid_t,
         permission: (NSAppleEventDescriptor) -> OSStatus,
         send: @escaping Send) throws {
        address = NSAppleEventDescriptor(processIdentifier: processID)
        try Self.checkPermission(permission(address))
        self.send = send
    }

    init(application: NSRunningApplication) throws {
        guard !application.isTerminated, application.activationPolicy == .regular,
              Self.supportedBundleIDs.contains(application.bundleIdentifier ?? "") else {
            throw Failure.unavailable
        }
        try self.init(processID: application.processIdentifier, permission: {
            Self.permission(address: $0, prompt: false)
        }, send: { event, options in
            guard !application.isTerminated else { throw Failure.unavailable }
            return try event.sendEvent(options: options, timeout: 2)
        })
    }

    static func permission(address: NSAppleEventDescriptor, prompt: Bool) -> OSStatus {
        withExtendedLifetime(address) {
            AEDeterminePermissionToAutomateTarget(address.aeDesc,
                AEEventClass(typeWildCard), AEEventID(typeWildCard), prompt)
        }
    }

    private static func checkPermission(_ status: OSStatus) throws {
        if status == errAEEventNotPermitted || status == errAEEventWouldRequireUserConsent {
            throw Failure.needsConsent
        }
        guard status == noErr else { throw Failure.unavailable }
    }

    func frontWindowMode() throws -> String? {
        guard let id = try windowIDs().first else { return nil }
        return try mode(of: window(id))
    }

    /// Resolves the same first window and active tab identity used by activeTab(),
    /// without fetching either URL or title.
    func activeTabMetadata() throws -> ActiveTabMetadata? {
        try activeTabTarget()?.metadata
    }

    func activeTab() throws -> (url: String, title: String)? {
        guard let target = try activeTabTarget(),
              target.metadata.mode == "normal",
              let tabID = target.tabID else { return nil }
        return try activeTabContent(target, tabID: tabID)
    }

    /// Captures content only when the exact window and tab preflighted by the
    /// caller remain the current capture target. The target is re-resolved once
    /// and that same pinned window/tab specifier is used for URL/title reads.
    func activeTab(matching expected: ActiveTabMetadata) throws -> (url: String, title: String)? {
        guard let target = try activeTabTarget(),
              target.metadata == expected,
              target.metadata.mode == "normal",
              let tabID = target.tabID else { throw Failure.unavailable }
        return try activeTabContent(target, tabID: tabID)
    }

    func inventory(browser: BrowserKind) throws -> [BrowserTab] {
        var tabs: [BrowserTab] = []
        for (windowIndex, id) in try windowIDs().enumerated() {
            let container = try window(id)
            guard try mode(of: container) == "normal" else { continue }
            let allTabs = try Self.object("CrTb", form: formAbsolutePosition,
                key: Self.all, container: container)
            for (tabIndex, tabID) in try identifiers(of: allTabs).enumerated() {
                let tab = try Self.object("CrTb", form: formUniqueID, key: tabID, container: container)
                let value = try content(of: tab)
                if !value.url.isEmpty {
                    tabs.append(BrowserTab(browser: browser, window: windowIndex + 1,
                        index: tabIndex + 1, url: value.url, title: value.title))
                }
            }
        }
        return tabs
    }

    private func windowIDs() throws -> [NSAppleEventDescriptor] {
        try identifiers(of: Self.object("cwin", form: formAbsolutePosition,
                                       key: Self.all, container: .null()))
    }

    private func identifiers(of object: NSAppleEventDescriptor) throws -> [NSAppleEventDescriptor] {
        let list = try get(Self.property("ID  ", of: object))
        guard list.descriptorType == typeAEList, list.numberOfItems <= 10_000 else {
            throw Failure.unavailable
        }
        return try (0..<list.numberOfItems).map { index in
            guard let id = list.atIndex(index + 1),
                  let text = id.stringValue, !text.isEmpty else { throw Failure.unavailable }
            return id
        }
    }

    private func window(_ id: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try Self.object("cwin", form: formUniqueID, key: id, container: .null())
    }

    private func activeTabTarget() throws -> ActiveTabTarget? {
        guard let id = try windowIDs().first, let windowID = id.stringValue,
              !windowID.isEmpty else { return nil }
        let container = try window(id)
        let windowMode = try mode(of: container)
        guard windowMode == "normal" else {
            return ActiveTabTarget(
                metadata: ActiveTabMetadata(windowID: windowID, mode: windowMode,
                                            activeTabID: nil),
                window: container,
                tabID: nil)
        }

        let active = try Self.property("acTa", of: container)
        let tabID = try get(Self.property("ID  ", of: active))
        guard let activeTabID = tabID.stringValue, !activeTabID.isEmpty else {
            throw Failure.unavailable
        }
        return ActiveTabTarget(
            metadata: ActiveTabMetadata(windowID: windowID, mode: windowMode,
                                        activeTabID: activeTabID),
            window: container,
            tabID: tabID)
    }

    private func activeTabContent(_ target: ActiveTabTarget,
                                  tabID: NSAppleEventDescriptor) throws -> (url: String, title: String)? {
        let tab = try Self.object("CrTb", form: formUniqueID, key: tabID,
                                  container: target.window)
        let content = try content(of: tab)
        return content.url.isEmpty ? nil : content
    }

    private func mode(of window: NSAppleEventDescriptor) throws -> String {
        let value = try text(Self.property("mode", of: window))
        guard value == "normal" || value == "incognito" else { throw Failure.unavailable }
        return value
    }

    private func content(of tab: NSAppleEventDescriptor) throws -> (url: String, title: String) {
        (try text(Self.property("URL ", of: tab)), try text(Self.property("pnam", of: tab)))
    }

    private func text(_ specifier: NSAppleEventDescriptor) throws -> String {
        guard let value = try get(specifier).stringValue else { throw Failure.unavailable }
        return value
    }

    private func get(_ specifier: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kAECoreSuite),
            eventID: AEEventID(kAEGetData), targetDescriptor: address,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(specifier, forKeyword: keyDirectObject)
        do {
            let reply = try send(event, Self.sendOptions)
            if let error = reply.paramDescriptor(forKeyword: keyErrorNumber), error.int32Value != 0 {
                try Self.checkPermission(error.int32Value)
            }
            guard let value = reply.paramDescriptor(forKeyword: keyDirectObject) else {
                throw Failure.unavailable
            }
            return value
        } catch let failure as Failure { throw failure }
        catch {
            let code = (error as NSError).code
            if code == Int(errAEEventNotPermitted) || code == Int(errAEEventWouldRequireUserConsent) {
                throw Failure.needsConsent
            }
            throw Failure.unavailable
        }
    }

    static func code(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }

    private static var all: NSAppleEventDescriptor {
        get throws {
            guard let descriptor = NSAppleEventDescriptor(descriptorType: typeAbsoluteOrdinal,
                data: NSAppleEventDescriptor(enumCode: OSType(kAEAll)).data) else {
                throw Failure.unavailable
            }
            return descriptor
        }
    }

    static func property(_ name: String, of container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        try object("prop", form: formPropertyID,
               key: NSAppleEventDescriptor(typeCode: code(name)), container: container)
    }

    static func object(_ type: String, form: Int, key: NSAppleEventDescriptor,
                       container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(type)), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(form)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(key, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let specifier = record.coerce(toDescriptorType: typeObjectSpecifier) else {
            throw Failure.unavailable
        }
        return specifier
    }
}
