import AppKit
import Foundation

/// Checks the real SwiftUI window without starting background sampling or updates.
@MainActor enum BrowserStartupCheck {
    static let enabled = CommandLine.arguments.contains("--check-app-startup")
    private static var started = false

    static func windowAppeared() {
        guard enabled, !started else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard let window = NSApplication.shared.windows.first(where: {
                $0.isVisible && $0.contentView != nil && $0.title == "browserdaddy"
            }) else { exit(EXIT_FAILURE) }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            FileHandle.standardOutput.write(Data("BrowserDaddy app startup verified\n".utf8))
            exit(EXIT_SUCCESS)
        }
    }
}
