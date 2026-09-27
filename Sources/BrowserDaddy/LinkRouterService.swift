import AppKit
import BrowserCore
import Carbon.HIToolbox

private func fourCharCode(_ s: String) -> OSType {
    s.utf8.reduce(0) { ($0 << 8) | OSType($1) }
}

/// Infra for the link router: receives GURL AppleEvents when BrowserDaddy
/// is the default browser, owns the Carbon global hotkeys, and drives the
/// picker panel. Behavior lives in AppModel — this is plumbing.
@MainActor
final class LinkRouterService: NSObject {
    static let shared = LinkRouterService()

    weak var model: AppModel?
    let picker = LinkPickerPanelController()
    private var pendingURL: URL?
    private var installed = false
    /// Last GURL receipt — set before routing, so a reopen event racing in
    /// while the link is still being forwarded also stays windowless.
    private var lastURLEventAt: Date?
    /// UI state at the moment the last link arrived — a window that was
    /// already up is the user's surface, not launch debris, and stays.
    private var hadUIWhenURLEventArrived = false
    /// The app that sent the last link — routing leaves the destination
    /// browser in the background, so focus goes back to the clicker.
    private var urlSender: NSRunningApplication?
    /// Pid of the last frontmost app that wasn't us — GURL delivery
    /// activates the handler before the event arrives, so this is where a
    /// clicked link came from. Written from the workspace observer's main
    /// queue; always read on the main actor — the unsafe marker just lets
    /// the non-Sendable notification block reach it.
    nonisolated(unsafe) private var lastNonSelfFrontmostPid: pid_t = 0

    /// A link was just delivered (and possibly routed) — UI surfaces must
    /// not appear right now. Covers the cold-launch race where a reopen
    /// lands between the GURL event and `open` finishing.
    var recentlyHandledURLEvent: Bool {
        guard let lastURLEventAt else { return false }
        return Date().timeIntervalSince(lastURLEventAt) < 3
    }

    private var uiOpenedByUserAt: Date?
    /// Menu/Dock opens stamp this — a window created right after a route
    /// is still the user's when they asked for it themselves.
    func markUserOpenedUI() { uiOpenedByUserAt = Date() }
    var recentlyOpenedUIByUser: Bool {
        guard let uiOpenedByUserAt else { return false }
        return Date().timeIntervalSince(uiOpenedByUserAt) < 3
    }

    // ⌃⌥O — clipboard link picker; ⌃⌥Space — move current tab.
    static let clipboardKey = (code: UInt32(kVK_ANSI_O), name: "⌃⌥O")
    static let moveTabKey = (code: UInt32(kVK_Space), name: "⌃⌥Space")
    static let modifiers = UInt32(controlKey | optionKey)
    private var hotKeyRefs: [EventHotKeyRef?] = []

    func install() {
        guard !installed else { return }
        installed = true
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(fourCharCode("GURL")),
            andEventID: AEEventID(fourCharCode("GURL")))
        hotKeyRefs = [
            GlobalHotKey.install(keyCode: Self.clipboardKey.code,
                                 modifiers: Self.modifiers) { [weak self] in
                Task { @MainActor in self?.model?.openClipboardLink() }
            },
            GlobalHotKey.install(keyCode: Self.moveTabKey.code,
                                 modifiers: Self.modifiers) { [weak self] in
                Task { @MainActor in self?.model?.moveCurrentTab() }
            },
        ]
        // Track who was frontmost before each activation — GURL delivery
        // activates us before the event arrives, so this remembers the
        // clicker to restore after background routing. Seeded now: a cold
        // launch's clicker was frontmost long before we existed.
        if let front = NSWorkspace.shared.frontmostApplication,
           front != NSRunningApplication.current {
            lastNonSelfFrontmostPid = front.processIdentifier
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  app != NSRunningApplication.current else { return }
            self?.lastNonSelfFrontmostPid = app.processIdentifier
        }
    }

    /// Clicked link while BrowserDaddy is default browser — silent routing.
    @objc private func handleGetURL(_ event: NSAppleEventDescriptor,
                                    withReply reply: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?
                .stringValue,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        lastURLEventAt = Date()
        // Delivery itself can activate us (LaunchServices brings the
        // handler forward to send GURL) — only a *visible window* means
        // the user actually had our UI up.
        hadUIWhenURLEventArrived =
            NSApplication.shared.windows.contains { $0.isVisible }
        if let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?
            .int32Value, pid != ProcessInfo.processInfo.processIdentifier {
            urlSender = NSRunningApplication(processIdentifier: pid)
        } else {
            urlSender = nil
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           front != NSRunningApplication.current {
            lastNonSelfFrontmostPid = front.processIdentifier
        }
        if let model {
            if model.route(url) { hideAfterRouting() }
        } else {
            pendingURL = url
        }
    }

    /// Called once the AppModel exists — replays a link that arrived during
    /// startup before the model was bound.
    func drainPending() {
        guard let url = pendingURL, let model else { return }
        pendingURL = nil
        if model.route(url) { hideAfterRouting() }
    }

    private func hideAfterRouting() {
        lastURLEventAt = Date()
        // Links sent while our UI was already up (History's "Open URL", or
        // an open main window) must not make the app vanish — only tear
        // down surfaces the URL launch itself may have created.
        if !hadUIWhenURLEventArrived {
            NSApplication.shared.windows.forEach { $0.orderOut(nil) }
            NSApplication.shared.hide(nil)
            NSApplication.shared.setActivationPolicy(.accessory)
            // A cold launch can create its SwiftUI window after the URL event.
            DispatchQueue.main.async {
                NSApplication.shared.windows.forEach { $0.orderOut(nil) }
                NSApplication.shared.hide(nil)
            }
        }
        // `-g` keeps the destination browser in the background; delivery
        // may have activated us, so hand focus back to the clicker.
        let candidates = [urlSender,
                          NSRunningApplication(processIdentifier: lastNonSelfFrontmostPid)]
        urlSender = nil
        if let restore = candidates.lazy.compactMap({ $0 })
            .first(where: { $0 != NSRunningApplication.current
                && !$0.isTerminated }) {
            restore.activate()
        }
    }
}

/// Carbon RegisterEventHotKey — system-wide hotkeys with no accessibility
/// or input-monitoring permission. C callbacks can't be actor-isolated, so
/// shared state sits in a lock-guarded box.
enum GlobalHotKey {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handlers: [UInt32: () -> Void] = [:]
        var dispatcherInstalled = false
        var nextID: UInt32 = 1
    }
    private static let state = State()

    @discardableResult
    static func install(keyCode: UInt32, modifiers: UInt32,
                        handler: @escaping () -> Void) -> EventHotKeyRef? {
        state.lock.lock()
        installDispatcherLocked()
        let id = state.nextID
        state.nextID += 1
        state.handlers[id] = handler
        state.lock.unlock()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: fourCharCode("BDLK"), id: id)
        RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                            GetEventDispatcherTarget(), 0, &ref)
        return ref
    }

    private static func installDispatcherLocked() {
        guard !state.dispatcherInstalled else { return }
        state.dispatcherInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let handler: (() -> Void)? = GlobalHotKey.state.lock.withLock {
                GlobalHotKey.state.handlers[hotKeyID.id]
            }
            if let handler {
                DispatchQueue.main.async { handler() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
