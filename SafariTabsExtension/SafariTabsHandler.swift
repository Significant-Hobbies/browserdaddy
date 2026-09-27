import Foundation
import SafariServices

/// Safari supplies a reliable Private Browsing flag per page. Never read a
/// page's URL or title until that flag is known to be false.
final class SafariTabsHandler: SFSafariExtensionHandler {
    private struct ScannedTab {
        let entry: SafariTabEntry
        let tab: SFSafariTab
    }

    override func messageReceivedFromContainingApp(
        withName messageName: String, userInfo: [String: Any]?
    ) {
        switch messageName {
        case "inventory":
            guard let requestID = userInfo?["requestID"] as? String else { return }
            collect(requestID: requestID)
        case "close", "focus":
            guard let window = userInfo?["window"] as? Int,
                  let index = userInfo?["index"] as? Int,
                  let expectedURL = userInfo?["url"] as? String,
                  let requestID = userInfo?["requestID"] as? String else { return }
            operate(messageName, window: window, index: index,
                    expectedURL: expectedURL, requestID: requestID)
        default:
            break
        }
    }

    private func collect(requestID: String) {
        scan { rows in
            let snapshot = SafariTabSnapshot(
                requestID: requestID, capturedAt: Date(),
                tabs: rows.map(\.entry))
            guard let root = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: SafariTabWire.groupID),
                  let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: root.appendingPathComponent(SafariTabWire.fileName),
                            options: .atomic)
        }
    }

    /// Number only windows and tabs that contain shareable regular pages.
    /// A private window never creates a gap in the app's visible numbering.
    private func scan(_ completion: @escaping ([ScannedTab]) -> Void) {
        SFSafariApplication.getAllWindows { windows in
            let windowsGroup = DispatchGroup()
            let lock = NSLock()
            var regular: [(window: Int, index: Int, tab: SFSafariTab,
                           url: String, title: String)] = []
            for (windowOffset, window) in windows.enumerated() {
                windowsGroup.enter()
                window.getAllTabs { tabs in
                    let tabsGroup = DispatchGroup()
                    for (tabOffset, tab) in tabs.enumerated() {
                        tabsGroup.enter()
                        tab.getActivePage { page in
                            guard let page else { tabsGroup.leave(); return }
                            page.getPropertiesWithCompletionHandler { properties in
                                defer { tabsGroup.leave() }
                                guard let properties,
                                      !properties.usesPrivateBrowsing else { return }
                                // Only now may URL/title cross into the
                                // regular-page inventory.
                                guard let entry = SafariTabWire.regularEntry(
                                    window: windowOffset + 1,
                                    index: tabOffset + 1,
                                    isPrivate: false, url: properties.url,
                                    title: properties.title) else { return }
                                lock.lock()
                                regular.append((windowOffset, tabOffset, tab,
                                                entry.url, entry.title))
                                lock.unlock()
                            }
                        }
                    }
                    tabsGroup.notify(queue: .global(qos: .utility)) {
                        windowsGroup.leave()
                    }
                }
            }
            windowsGroup.notify(queue: .global(qos: .utility)) {
                let ordered = regular.sorted {
                    ($0.window, $0.index) < ($1.window, $1.index)
                }
                var windowNumbers: [Int: Int] = [:]
                var tabCounts: [Int: Int] = [:]
                let rows = ordered.map { item -> ScannedTab in
                    let visibleWindow = windowNumbers[item.window] ?? {
                        let next = windowNumbers.count + 1
                        windowNumbers[item.window] = next
                        return next
                    }()
                    let visibleIndex = (tabCounts[item.window] ?? 0) + 1
                    tabCounts[item.window] = visibleIndex
                    let entry = SafariTabEntry(window: visibleWindow,
                                               index: visibleIndex,
                                               url: item.url,
                                               title: item.title)
                    return ScannedTab(entry: entry, tab: item.tab)
                }
                completion(rows)
            }
        }
    }

    private func operate(_ action: String, window: Int, index: Int,
                         expectedURL: String, requestID: String) {
        guard window > 0, index > 0 else {
            finishAction(requestID, applied: false)
            return
        }
        scan { rows in
            guard let match = rows.first(where: {
                $0.entry.window == window && $0.entry.index == index
                    && $0.entry.url == expectedURL
            }) else {
                self.finishAction(requestID, applied: false)
                return
            }
            if action == "close" {
                match.tab.close()
                self.finishAction(requestID, applied: true)
            } else {
                match.tab.activate {
                    self.finishAction(requestID, applied: true)
                }
            }
        }
    }

    private func finishAction(_ requestID: String, applied: Bool) {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SafariTabWire.groupID),
              let data = try? JSONEncoder().encode(
                SafariTabActionResult(requestID: requestID, applied: applied))
        else { return }
        try? data.write(
            to: root.appendingPathComponent(
                SafariTabWire.actionFileName(requestID: requestID)),
            options: .atomic)
    }
}
