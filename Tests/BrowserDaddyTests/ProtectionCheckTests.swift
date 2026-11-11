import BrowserCore
import XCTest
@testable import BrowserDaddy

final class ProtectionCheckTests: XCTestCase {
    func testAnyProtectedHTTPResponseWarnsIncludingDenialsAndRedirects() {
        for target in ProtectionCheckTarget.allCases.filter(\.isProtected) {
            for status in [200, 301, 302, 403, 404, 500] {
                var results = failures
                results[target] = .httpStatus(status)
                let report = report(results, controlBlocked: true)
                XCTAssertEqual(report.assessment, .protectedReachable)
                XCTAssertTrue(report.summary.contains("reachable from BrowserDaddy"))
            }
        }
    }

    func testFailuresNeverProveBlockingAndRequireAnAllowedControl() {
        for failure in [ProbeObservation.timeout, .dns, .tls, .transport] {
            var results = Dictionary(uniqueKeysWithValues: ProtectionCheckTarget.allCases.map { ($0, failure) })
            XCTAssertEqual(report(results).assessment, .inconclusive)
            results[.allowed] = .httpStatus(403)
            XCTAssertEqual(report(results).assessment, .samplesUnreachable)
            XCTAssertTrue(report(results).summary.contains("cause is unverified"))
            XCTAssertEqual(report(results, controlBlocked: true).assessment, .inconclusive)
            results[.youtube] = .cancelled
            XCTAssertEqual(report(results).assessment, .inconclusive)
            results[.youtube] = nil
            XCTAssertEqual(report(results).assessment, .inconclusive)
        }
    }

    func testEphemeralConfigurationHasNoPersistentStoresOrCredentials() {
        let configuration = HTTPSProtectionProbe.sessionConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 5)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 8)
        XCTAssertFalse(configuration.waitsForConnectivity)
    }

    @MainActor
    func testRealSessionUsesFixedHEADRequestsWithoutCookies() async throws {
        ProtectionProbeURLProtocol.store.reset(.status(403))
        let prober = HTTPSProtectionProbe(protocolClasses: [ProtectionProbeURLProtocol.self])
        let result = await prober.probe(.reddit)
        XCTAssertEqual(result, .httpStatus(403))
        let requests = ProtectionProbeURLProtocol.store.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url, ProtectionCheckTarget.reddit.url)
        XCTAssertEqual(request.httpMethod, "HEAD")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testRealSessionDoesNotFollowRedirectsOutsideTheAllowlist() async {
        ProtectionProbeURLProtocol.store.reset(.redirect)
        let result = await HTTPSProtectionProbe(protocolClasses: [ProtectionProbeURLProtocol.self]).probe(.youtube)
        XCTAssertEqual(result, .httpStatus(302))
        XCTAssertEqual(ProtectionProbeURLProtocol.store.requests.map(\.url), [ProtectionCheckTarget.youtube.url])
    }

    func testRealSessionClassifiesDNSAndTLSFailures() async {
        let prober = HTTPSProtectionProbe(protocolClasses: [ProtectionProbeURLProtocol.self])
        for (code, observation) in [(URLError.Code.dnsLookupFailed, ProbeObservation.dns),
                                    (.serverCertificateUntrusted, .tls), (.cannotConnectToHost, .transport),
                                    (.timedOut, .timeout)] {
            ProtectionProbeURLProtocol.store.reset(.failure(code))
            let result = await prober.probe(.instagram)
            XCTAssertEqual(result, observation)
        }
    }

    @MainActor
    func testCancellationStopsTheRealSession() async throws {
        ProtectionProbeURLProtocol.store.reset(.hang)
        let prober = HTTPSProtectionProbe(protocolClasses: [ProtectionProbeURLProtocol.self])
        let task = Task { await prober.probe(.youtube) }
        try await waitUntil { ProtectionProbeURLProtocol.store.requests.count == 1 }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        try await waitUntil { ProtectionProbeURLProtocol.store.stops == 1 }
    }

    @MainActor
    func testNoAutostartAndIneligibleOrPreviewStartsPerformNoNetwork() async {
        let prober = HeldProtectionProbe()
        let model = ProtectionCheckModel(prober: prober, networkAllowed: true)
        XCTAssertEqual(model.state, .idle)
        model.start(configuration: BlockingConfiguration(), eligible: false)
        let preview = ProtectionCheckModel(prober: prober, networkAllowed: false)
        preview.start(configuration: BlockingConfiguration(), eligible: true)
        for _ in 0..<10 { await Task.yield() }
        let count = await prober.count
        XCTAssertEqual(count, 0)
        XCTAssertEqual(model.state, .idle)
        XCTAssertEqual(preview.state, .idle)
    }

    @MainActor
    func testSingleFlightAndGenerationRejectResultsAfterInvalidation() async throws {
        let prober = HeldProtectionProbe()
        let model = ProtectionCheckModel(prober: prober, networkAllowed: true)
        model.start(configuration: BlockingConfiguration(), eligible: true)
        model.start(configuration: BlockingConfiguration(), eligible: true)
        try await waitUntil { await prober.count == 4 }
        model.invalidate()
        XCTAssertEqual(model.state, .stale)
        model.start(configuration: BlockingConfiguration(), eligible: true)
        try await waitUntil { await prober.count == 8 }
        await prober.completeFirstBatch(reachable: true)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(model.state, .running)
        XCTAssertTrue(model.observations.isEmpty)
        await prober.completeFirstBatch(reachable: false)
        try await waitUntil { !model.isRunning }
        guard case .finished(let report) = model.state else { return XCTFail("Expected completed current generation") }
        XCTAssertEqual(report.assessment, .samplesUnreachable)
    }

    @MainActor
    func testCancelRejectsLateResults() async throws {
        let prober = HeldProtectionProbe()
        let model = ProtectionCheckModel(prober: prober, networkAllowed: true)
        model.start(configuration: BlockingConfiguration(), eligible: true)
        try await waitUntil { await prober.count == 4 }
        model.cancel()
        await prober.completeFirstBatch(reachable: true)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(model.state, .cancelled)
        XCTAssertTrue(model.observations.isEmpty)
    }

    @MainActor
    func testDeadlineTerminatesAllFourRealRequests() async throws {
        ProtectionProbeURLProtocol.store.reset(.hang)
        let model = ProtectionCheckModel(prober: HTTPSProtectionProbe(protocolClasses: [ProtectionProbeURLProtocol.self]),
                                         deadline: .milliseconds(150), networkAllowed: true)
        model.start(configuration: BlockingConfiguration(), eligible: true)
        try await waitUntil { !model.isRunning }
        guard case .finished(let report) = model.state else { return XCTFail("Expected deadline report") }
        XCTAssertEqual(report.observations.count, 4)
        XCTAssertTrue(report.observations.values.allSatisfy { $0 == .timeout })
        XCTAssertEqual(report.assessment, .inconclusive)
        try await waitUntil { ProtectionProbeURLProtocol.store.stops == 4 }
        XCTAssertEqual(ProtectionProbeURLProtocol.store.requests.count, 4)
    }

    @MainActor
    func testBlockedControlRemainsInconclusiveEvenIfItResponds() async throws {
        let prober = HeldProtectionProbe()
        let model = ProtectionCheckModel(prober: prober, networkAllowed: true)
        var configuration = BlockingConfiguration()
        configuration.sites.insert(BlockingHostname("example.com")!)
        model.start(configuration: configuration, eligible: true)
        try await waitUntil { await prober.count == 4 }
        await prober.completeFirstBatch(reachable: false)
        try await waitUntil { !model.isRunning }
        guard case .finished(let report) = model.state else { return XCTFail("Expected report") }
        XCTAssertTrue(report.controlBlockedByRules)
        XCTAssertEqual(report.assessment, .inconclusive)
        XCTAssertTrue(report.summary.contains("blocked by your current rules"))
    }

    private var failures: [ProtectionCheckTarget: ProbeObservation] {
        Dictionary(uniqueKeysWithValues: ProtectionCheckTarget.allCases.map { ($0, .timeout) })
    }

    private func report(_ observations: [ProtectionCheckTarget: ProbeObservation], controlBlocked: Bool = false) -> ProtectionCheckReport {
        ProtectionCheckReport(checkedAt: Date(timeIntervalSince1970: 0), observations: observations, controlBlockedByRules: controlBlocked)
    }

    @MainActor
    private func waitUntil(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<2000 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for protection check", file: file, line: line)
    }
}

private actor HeldProtectionProbe: ProtectionProbing {
    private var pending: [(ProtectionCheckTarget, CheckedContinuation<ProbeObservation, Never>)] = []
    private(set) var count = 0

    func probe(_ target: ProtectionCheckTarget) async -> ProbeObservation {
        count += 1
        return await withCheckedContinuation { pending.append((target, $0)) }
    }

    func completeFirstBatch(reachable: Bool) {
        let batch = Array(pending.prefix(4))
        pending.removeFirst(batch.count)
        for (target, continuation) in batch {
            continuation.resume(returning: reachable || target == .allowed ? .httpStatus(200) : .timeout)
        }
    }
}

private final class ProtectionProbeURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable { case status(Int), redirect, hang, failure(URLError.Code) }
    static let store = Store()

    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URLRequest] = []
        private var stopped = 0
        private var reply = Reply.hang

        var requests: [URLRequest] { lock.withLock { recorded } }
        var stops: Int { lock.withLock { stopped } }
        func reset(_ reply: Reply) { lock.withLock { recorded = []; stopped = 0; self.reply = reply } }
        func start(_ request: URLRequest) -> Reply { lock.withLock { recorded.append(request); return reply } }
        func stop() { lock.withLock { stopped += 1 } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.store.start(request) {
        case .status(let status):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Set-Cookie": "protection-test=1; Secure", "Content-Length": "999999"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect:
            let destination = URL(string: "https://must-not-follow.invalid/")!
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": destination.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
        case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang: break
        }
    }

    override func stopLoading() { Self.store.stop() }
}
