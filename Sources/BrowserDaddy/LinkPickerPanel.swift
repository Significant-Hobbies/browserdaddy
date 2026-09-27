import AppKit
import BrowserCore
import SwiftUI

/// Floating target picker for explicit invocations (clipboard hotkey,
/// move-tab hotkey). Clicked links never see this — they route silently.
@MainActor
final class LinkPickerState: ObservableObject {
    @Published var url = ""
    @Published var targets: [LinkTarget] = []
    @Published var profileNames: [String: String] = [:]
    @Published var selection = 0
    @Published var matchedRule: RouteRule?

    func label(for target: LinkTarget) -> String {
        guard !target.profile.isEmpty else { return target.browser.displayName }
        let name = profileNames[target.id]
        let shown = name.map { $0 == target.profile ? $0
            : "\($0) (\(target.profile))" } ?? target.profile
        return "\(target.browser.displayName) · \(shown)"
    }
}

/// Borderless windows refuse key status by default — without this the
/// picker shows but never sees arrow/digit/⏎ keystrokes.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class LinkPickerPanelController {
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var onPick: ((LinkTarget) -> Void)?
    private var previousApp: NSRunningApplication?
    private let state = LinkPickerState()

    /// Explicit invocations only (⌃⌥O, ⌃⌥Space, menu) — the panel takes
    /// focus and answers keystrokes. Nothing floats this on its own;
    /// copying a link never surfaces UI.
    func show(url: URL, targets: [LinkTarget],
              profileNames: [String: String] = [:], preselect: LinkTarget?,
              matchedRule: RouteRule?,
              onPick: @escaping (LinkTarget) -> Void) {
        guard !targets.isEmpty else { return }
        dismiss()
        state.url = url.absoluteString
        state.targets = targets
        state.profileNames = profileNames
        state.matchedRule = matchedRule
        state.selection = preselect.flatMap { t in targets.firstIndex(of: t) } ?? 0
        self.onPick = onPick
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier
            ? nil : frontmost

        let height = CGFloat(64 + targets.count * 36 + 16)
        let frame = NSRect(x: 0, y: 0, width: 400, height: height)
        let panel = KeyablePanel(contentRect: frame,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.contentView = NSHostingView(rootView: LinkPickerView(
            state: state, onConfirm: { [weak self] in self?.confirmSelection() }))
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
        if let bounds = screen?.visibleFrame {
            let x = min(max(pointer.x - frame.width / 2, bounds.minX),
                        bounds.maxX - frame.width)
            let y = min(max(pointer.y - frame.height - 12, bounds.minY),
                        bounds.maxY - frame.height)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }
        NSApp.unhideWithoutActivation()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, self.panel != nil else { return event }
            return self.handleKey(event) ? nil : event
        }
        // Clicking away resigns key/active — autoclose like every
        // floating chooser (Esc only reaches a local monitor while
        // we're frontmost).
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        self.panel = panel
    }

    func dismiss(restoreFocus: Bool = false) {
        let appToRestore = restoreFocus ? previousApp : nil
        previousApp = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        resignObserver = nil
        onPick = nil
        panel?.orderOut(nil)
        panel = nil
        appToRestore?.activate()
    }

    func confirmSelection() {
        guard state.targets.indices.contains(state.selection) else { return }
        let target = state.targets[state.selection]
        let pick = onPick
        dismiss()
        pick?(target)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:  // esc
            dismiss(restoreFocus: true)
            return true
        case 36, 76:  // return / numpad enter
            confirmSelection()
            return true
        case 125:  // down
            state.selection = min(state.selection + 1, state.targets.count - 1)
            return true
        case 126:  // up
            state.selection = max(state.selection - 1, 0)
            return true
        default:
            // digits 1–9 jump straight to a target — bare keys only, so
            // ⌘1-style chords still reach whatever the user meant them for
            if event.modifierFlags
                .intersection([.command, .control, .option]).isEmpty,
               let chars = event.charactersIgnoringModifiers,
               let digit = chars.first, digit.isNumber, digit != "0",
               let idx = Int(String(digit)), idx <= state.targets.count {
                state.selection = idx - 1
                confirmSelection()
                return true
            }
            return false
        }
    }
}

private struct LinkPickerView: View {
    @ObservedObject var state: LinkPickerState
    var onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.matchedRule != nil
                     ? "Rule “\(state.matchedRule!.pattern)” matched — pick a browser"
                     : "Open in…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BrowserTheme.secondaryInk)
                Text(state.url)
                    .font(.callout.monospaced())
                    .foregroundStyle(BrowserTheme.mintInk)
                    .lineLimit(1).truncationMode(.middle)
            }

            VStack(spacing: 2) {
                ForEach(Array(state.targets.enumerated()), id: \.element.id) {
                    index, target in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(BrowserTheme.secondaryInk)
                            .frame(width: 14)
                        Text(state.label(for: target))
                            .font(.callout)
                            .foregroundStyle(BrowserTheme.ink)
                        Spacer()
                        if index == state.selection {
                            Text("⏎")
                                .foregroundStyle(BrowserTheme.mintInk)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(index == state.selection
                                ? BrowserTheme.mintInk.opacity(0.16) : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.selection = index
                        onConfirm()
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 400)
        .background(Color.black.opacity(0.96),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(BrowserTheme.mintInk.opacity(0.35), lineWidth: 1))
        .preferredColorScheme(.dark)
    }
}
