import AppKit
import BrowserCore
import Foundation
import SafariServices

/// Asks the bundled Safari app extension for normal tabs. Responses expire
/// immediately and stay in the shared app-group container, never the archive.
enum SafariTabsBridge {
    private static var extensionID: String {
        SafariTabWire.extensionID(hostBundleID:
            Bundle.main.bundleIdentifier ?? "com.significanthobbies.browserdaddy")
    }

    private static var snapshotURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SafariTabWire.groupID)?
            .appendingPathComponent(SafariTabWire.fileName)
    }

    private static var groupRoot: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SafariTabWire.groupID)
    }

    static func inventory() async -> TabSourceState {
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: BrowserKind.safari.bundleIdentifier).isEmpty
        else { return .notRunning }
        let enabled = await withCheckedContinuation { continuation in
            SFSafariExtensionManager.getStateOfSafariExtension(
                withIdentifier: extensionID) { state, _ in
                    continuation.resume(returning: state?.isEnabled == true)
                }
        }
        guard enabled else { return .needsConsent }
        guard let snapshotURL else {
            return .failed("Safari tab sharing is unavailable")
        }
        let requestID = UUID().uuidString
        let error = await dispatch("inventory", userInfo: ["requestID": requestID])
        if error != nil { return .failed("Safari extension did not accept the request") }
        for _ in 0..<40 {
            if let data = try? Data(contentsOf: snapshotURL),
               let snapshot = try? JSONDecoder().decode(SafariTabSnapshot.self,
                                                         from: data),
               snapshot.requestID == requestID,
               abs(snapshot.capturedAt.timeIntervalSinceNow) < 10 {
                try? FileManager.default.removeItem(at: snapshotURL)
                let tabs = snapshot.tabs.compactMap { entry -> BrowserTab? in
                    guard entry.window > 0, entry.index > 0,
                          let url = URL(string: entry.url),
                          ["http", "https"].contains(url.scheme?.lowercased() ?? "")
                    else { return nil }
                    return BrowserTab(browser: .safari, window: entry.window,
                                      index: entry.index, url: entry.url,
                                      title: entry.title)
                }
                return tabs.isEmpty ? .noWindows : .tabs(tabs)
            }
            try? await Task.sleep(for: .milliseconds(75))
        }
        return .failed("Safari did not return tabs — check its extension access")
    }

    static func operate(_ action: String, tab: BrowserTab) async -> TabSourceState {
        guard tab.browser == .safari,
              action == "close" || action == "focus" else { return .unsupported }
        let requestID = UUID().uuidString
        guard let actionURL = groupRoot?.appendingPathComponent(
            SafariTabWire.actionFileName(requestID: requestID))
        else { return .failed("Safari tab sharing is unavailable") }
        sweepStaleActionResults()
        let error = await dispatch(action, userInfo: [
            "window": tab.window, "index": tab.index, "url": tab.url,
            "requestID": requestID,
        ])
        if error != nil { return .failed("Safari extension did not accept the action") }
        for _ in 0..<40 {
            if let data = try? Data(contentsOf: actionURL),
               let result = try? JSONDecoder().decode(SafariTabActionResult.self,
                                                       from: data),
               result.requestID == requestID {
                try? FileManager.default.removeItem(at: actionURL)
                return result.applied ? .tabs([])
                    : .failed("Safari tab changed or is private; no action taken")
            }
            try? await Task.sleep(for: .milliseconds(75))
        }
        return .failed("Safari did not confirm the tab action")
    }

    /// Unclaimed results from crashed/interrupted operations — each is
    /// tiny, but they would accumulate forever otherwise. Anything older
    /// than a minute is well past the 3s read timeout.
    private static func sweepStaleActionResults() {
        guard let root = groupRoot,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = Date().addingTimeInterval(-60)
        for entry in entries
        where entry.lastPathComponent.hasPrefix("safari-tab-action-") {
            let mtime = (try? entry.resourceValues(
                forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            if mtime < cutoff { try? FileManager.default.removeItem(at: entry) }
        }
    }

    static func openPreferences() {
        SFSafariApplication.showPreferencesForExtension(
            withIdentifier: extensionID, completionHandler: nil)
    }

    private static func dispatch(_ name: String,
                                 userInfo: [String: Any]) async -> Error? {
        await withCheckedContinuation { continuation in
            SFSafariApplication.dispatchMessage(
                withName: name,
                toExtensionWithIdentifier: extensionID,
                userInfo: userInfo) { error in
                    continuation.resume(returning: error)
                }
        }
    }
}
