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
                "macOS did not confirm BrowserDaddy for both HTTP and HTTPS links."
            }
        }
    }

    static func register(
        bundleID: String?,
        setDefault: (String) async throws -> Void,
        handlerID: (String) -> String
    ) async throws {
        guard let bundleID, !bundleID.isEmpty else {
            throw Error.missingBundleIdentifier
        }
        for scheme in ["http", "https"] {
            try await setDefault(scheme)
        }
        guard ["http", "https"].allSatisfy({ handlerID($0) == bundleID }) else {
            throw Error.handlerMismatch
        }
    }
}
