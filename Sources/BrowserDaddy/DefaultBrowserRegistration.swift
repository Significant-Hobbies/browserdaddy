import Foundation

@MainActor
enum DefaultBrowserRegistration {
    enum Error: LocalizedError {
        case missingBundleIdentifier
        case handlerMismatch

        var errorDescription: String? {
            switch self {
            case .missingBundleIdentifier:
                "This copy of BrowserDaddy has no application identifier."
            case .handlerMismatch:
                "macOS did not confirm this copy of BrowserDaddy for both HTTP and HTTPS links."
            }
        }
    }

    static func register(
        bundleID: String?,
        applicationURL: URL,
        setDefault: (String) async throws -> Void,
        handlerID: (URL) -> String,
        handlerURL: (String) -> URL?
    ) async throws {
        guard let bundleID, !bundleID.isEmpty else {
            throw Error.missingBundleIdentifier
        }
        for scheme in ["http", "https"] {
            try await setDefault(scheme)
        }
        guard ["http", "https"].allSatisfy({ scheme in
            guard let resolvedURL = handlerURL(scheme) else { return false }
            return handlerID(resolvedURL) == bundleID
                && isSameApplication(resolvedURL, as: applicationURL)
        }) else {
            throw Error.handlerMismatch
        }
    }

    static func isSameApplication(_ handlerURL: URL?, as applicationURL: URL) -> Bool {
        guard let handlerURL else { return false }
        return handlerURL.resolvingSymlinksInPath().standardizedFileURL.path
            == applicationURL.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
