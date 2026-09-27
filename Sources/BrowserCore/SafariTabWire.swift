import Foundation

/// A short-lived, local-only response shared by the app and its Safari app
/// extension. The extension filters private pages before constructing this.
public enum SafariTabWire {
    public static let groupID = "group.com.significanthobbies.browserdaddy"
    public static func extensionID(hostBundleID: String) -> String {
        hostBundleID + ".safaritabs"
    }
    public static let fileName = "safari-tabs.json"
    /// Results are per-request — a shared file would let a later action
    /// overwrite an earlier result before the app reads it.
    public static func actionFileName(requestID: String) -> String {
        "safari-tab-action-\(requestID).json"
    }

    /// Unknown privacy state is excluded, just like Private Browsing.
    public static func regularEntry(window: Int, index: Int,
                                    isPrivate: Bool?, url: URL?,
                                    title: String?) -> SafariTabEntry? {
        guard isPrivate == false, window > 0, index > 0,
              let url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { return nil }
        return SafariTabEntry(window: window, index: index,
                              url: url.absoluteString, title: title ?? "")
    }
}

public struct SafariTabActionResult: Codable, Sendable {
    public let requestID: String
    public let applied: Bool

    public init(requestID: String, applied: Bool) {
        self.requestID = requestID
        self.applied = applied
    }
}

public struct SafariTabEntry: Codable, Sendable {
    public let window: Int
    public let index: Int
    public let url: String
    public let title: String

    public init(window: Int, index: Int, url: String, title: String) {
        self.window = window
        self.index = index
        self.url = url
        self.title = title
    }
}

public struct SafariTabSnapshot: Codable, Sendable {
    public let requestID: String
    public let capturedAt: Date
    public let tabs: [SafariTabEntry]

    public init(requestID: String, capturedAt: Date, tabs: [SafariTabEntry]) {
        self.requestID = requestID
        self.capturedAt = capturedAt
        self.tabs = tabs
    }
}
