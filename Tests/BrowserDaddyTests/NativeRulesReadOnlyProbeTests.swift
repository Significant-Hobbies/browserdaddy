import CryptoKit
import Foundation
import XCTest
@testable import BrowserCore
@testable import BrowserDaddy

/// Reads native preferences once, then evaluates existing pure maintenance code.
/// Never creates BlockingController or calls any recovery-save/apply/activation path.
@MainActor
final class NativeRulesReadOnlyProbeTests: XCTestCase {
    func testInstalledNativeRulesNeedNoRecovery() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["BROWSERDADDY_NATIVE_RULES_READ_ONLY_PROBE"] == "1")
        var report: [String: Bool] = [
            "qualificationAvailable": false,
            "nativeSnapshotRead": false,
            "qualificationPassed": false
        ]
        do {
            let snapshot = try await SystemBlockingPreferences().load()
            report["nativeSnapshotRead"] = true
            report["nativeEnabled"] = snapshot.enabled
            report["currentPayloadPresent"] = snapshot.payload != nil
            report["legacyPayloadPresent"] = snapshot.legacyPayload != nil

            guard let candidatePath = environment["BROWSERDADDY_CANDIDATE_RESOURCE_BUNDLE_PATH"] else {
                throw ProbeUnavailable.missingCatalog
            }
            let installedURL = URL(fileURLWithPath: "/Applications/BrowserDaddy.app/Contents/Resources/BrowserDaddy_BrowserDaddy.bundle", isDirectory: true)
            let candidateURL = URL(fileURLWithPath: candidatePath, isDirectory: true)
            guard candidateURL.lastPathComponent == "BrowserDaddy_BrowserDaddy.bundle",
                  candidateURL.resolvingSymlinksInPath() != installedURL.resolvingSymlinksInPath(),
                  let installedBundle = Bundle(url: installedURL),
                  let candidateBundle = Bundle(url: candidateURL) else { throw ProbeUnavailable.missingCatalog }

            var installedData: [BlockingCategory: Data] = [:]
            var candidateData: [BlockingCategory: Data] = [:]
            var identical = true
            var integrityValid = true
            for category in BlockingCategory.allCases {
                let name = category == .adult ? "Adult" : "Gambling"
                guard let installedResource = installedBundle.url(forResource: name, withExtension: "txt"),
                      let candidateResource = candidateBundle.url(forResource: name, withExtension: "txt") else {
                    throw ProbeUnavailable.missingCatalog
                }
                let installed = try Data(contentsOf: installedResource)
                let candidate = try Data(contentsOf: candidateResource)
                installedData[category] = installed
                candidateData[category] = candidate
                identical = identical && installed == candidate
                let expected = BlockingListCatalog.rawDigests[category]
                integrityValid = integrityValid && Self.digest(installed) == expected && Self.digest(candidate) == expected
            }
            report["catalogsIdentical"] = identical
            report["catalogIntegrityValid"] = integrityValid
            let installedSnapshot = installedData
            let candidateSnapshot = candidateData
            let installedCatalog = BlockingListCatalog { category in
                guard let data = installedSnapshot[category] else { throw ProbeUnavailable.missingCatalog }
                return data
            }
            let candidateCatalog = BlockingListCatalog { category in
                guard let data = candidateSnapshot[category] else { throw ProbeUnavailable.missingCatalog }
                return data
            }
            let (_, installedWarning, installedIncomplete) = try snapshot.maintenanceRules(catalog: installedCatalog)
            let (_, candidateWarning, candidateIncomplete) = try snapshot.maintenanceRules(catalog: candidateCatalog)
            report["installedMaintenanceWarningEmpty"] = installedWarning.isEmpty
            report["candidateMaintenanceWarningEmpty"] = candidateWarning.isEmpty
            report["installedRecoveryIncomplete"] = installedIncomplete
            report["candidateRecoveryIncomplete"] = candidateIncomplete
            report["qualificationAvailable"] = true
            report["qualificationPassed"] = snapshot.enabled && identical && integrityValid
                && installedWarning.isEmpty && candidateWarning.isEmpty
                && !installedIncomplete && !candidateIncomplete
        } catch {
            // Do not print native payloads, recovered rules, error descriptions or domains.
            report["qualificationAvailable"] = false
            report["qualificationPassed"] = false
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        XCTAssertTrue(report["qualificationPassed"] == true,
                      "Read-only native-rule qualification did not pass; live protection was not modified.")
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum ProbeUnavailable: Error { case missingCatalog }
