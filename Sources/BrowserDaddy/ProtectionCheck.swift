import Foundation

enum ProtectionCheckTarget: String, CaseIterable, Sendable, Identifiable {
    case allowed = "example.com"
    case youtube = "youtube.com"
    case reddit = "reddit.com"
    case instagram = "instagram.com"

    var id: String { rawValue }
    var url: URL { URL(string: "https://\(rawValue)/")! }
    var isProtected: Bool { self != .allowed }
}

enum ProbeObservation: Equatable, Sendable {
    case httpStatus(Int), timeout, dns, tls, transport, cancelled

    var reachedServer: Bool {
        if case .httpStatus(let status) = self { return (100...599).contains(status) }
        return false
    }

    var label: String {
        switch self {
        case .httpStatus(let status): return "HTTP \(status) · reachable"
        case .timeout: return "Timed out"
        case .dns: return "DNS failed"
        case .tls: return "TLS failed"
        case .transport: return "Connection failed"
        case .cancelled: return "Cancelled"
        }
    }
}

struct ProtectionCheckReport: Equatable, Sendable {
    enum Assessment: Equatable, Sendable {
        case protectedReachable, samplesUnreachable, inconclusive
    }

    let checkedAt: Date
    let observations: [ProtectionCheckTarget: ProbeObservation]
    let controlBlockedByRules: Bool

    var assessment: Assessment {
        if ProtectionCheckTarget.allCases.contains(where: { $0.isProtected && observations[$0]?.reachedServer == true }) {
            return .protectedReachable
        }
        if !controlBlockedByRules, observations[.allowed]?.reachedServer == true,
           ProtectionCheckTarget.allCases.filter(\.isProtected).allSatisfy({
               guard let observation = observations[$0], observation != .cancelled else { return false }
               return !observation.reachedServer
           }) {
            return .samplesUnreachable
        }
        return .inconclusive
    }

    var summary: String {
        switch assessment {
        case .protectedReachable: return "Warning: a protected sample is reachable from BrowserDaddy."
        case .samplesUnreachable: return "Protected samples were unreachable; the cause is unverified."
        case .inconclusive:
            if controlBlockedByRules {
                return "Inconclusive: example.com is blocked by your current rules, so it cannot serve as the allowed control."
            }
            return observations[.allowed]?.reachedServer == true
                ? "Inconclusive: the check did not complete all protected samples."
                : "Inconclusive: the allowed control did not establish connectivity."
        }
    }
}

protocol ProtectionProbing: Sendable {
    func probe(_ target: ProtectionCheckTarget) async -> ProbeObservation
}

struct HTTPSProtectionProbe: ProtectionProbing {
    // Only tests replace the protocol stack. Production always uses an ephemeral session.
    let protocolClasses: [AnyClass]?
    init(protocolClasses: [AnyClass]? = nil) { self.protocolClasses = protocolClasses }

    static func sessionConfiguration(protocolClasses: [AnyClass]? = nil) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.waitsForConnectivity = false
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return configuration
    }

    func probe(_ target: ProtectionCheckTarget) async -> ProbeObservation {
        let request = HeaderProbe(target: target, protocolClasses: protocolClasses)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { request.start($0) }
        } onCancel: {
            request.finish(.cancelled)
        }
    }
}

private final class HeaderProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let target: ProtectionCheckTarget
    private let protocolClasses: [AnyClass]?
    private var continuation: CheckedContinuation<ProbeObservation, Never>?
    private var result: ProbeObservation?
    private var session: URLSession?

    init(target: ProtectionCheckTarget, protocolClasses: [AnyClass]?) {
        self.target = target
        self.protocolClasses = protocolClasses
    }

    func start(_ continuation: CheckedContinuation<ProbeObservation, Never>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
            return
        }
        self.continuation = continuation
        let session = URLSession(configuration: HTTPSProtectionProbe.sessionConfiguration(protocolClasses: protocolClasses),
                                 delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: target.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        request.httpShouldHandleCookies = false
        session.dataTask(with: request).resume()
        lock.unlock()
    }

    func finish(_ observation: ProbeObservation) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = observation
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        lock.unlock()
        // Cancelling after headers prevents a server that ignores HEAD from streaming a body.
        session?.invalidateAndCancel()
        continuation?.resume(returning: observation)
    }

    private func observation(for response: URLResponse) -> ProbeObservation {
        guard let http = response as? HTTPURLResponse, http.url == target.url,
              (100...599).contains(http.statusCode) else { return .transport }
        return .httpStatus(http.statusCode)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        finish(observation(for: response))
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        finish(observation(for: response))
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error = error as? URLError else { finish(.transport); return }
        switch error.code {
        case .cancelled: finish(.cancelled)
        case .timedOut: finish(.timeout)
        case .cannotFindHost, .dnsLookupFailed: finish(.dns)
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired: finish(.tls)
        default: finish(.transport)
        }
    }
}
