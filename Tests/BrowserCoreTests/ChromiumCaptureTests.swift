import AppKit
import XCTest
@testable import BrowserCore

final class ChromiumCaptureTests: XCTestCase {
    func testSelectionUsesFrontmostGUIOrUniqueGUIAndNeverArbitraryProcess() throws {
        let headless = BrowserProcess.Candidate(pid: 10, regular: false)
        let first = BrowserProcess.Candidate(pid: 20, regular: true)
        let second = BrowserProcess.Candidate(pid: 30, regular: true)
        XCTAssertEqual(try BrowserProcess.select([headless, first], frontmost: nil), 20)
        XCTAssertEqual(try BrowserProcess.select([headless, first, second], frontmost: 30), 30)
        XCTAssertEqual(try BrowserProcess.select([headless, first], frontmost: 10), 20)
        XCTAssertThrowsError(try BrowserProcess.select([first, second], frontmost: nil))
        XCTAssertThrowsError(try BrowserProcess.select([headless], frontmost: 10))
        XCTAssertThrowsError(try BrowserProcess.select([], frontmost: nil))
    }

    func testUnboundActionsRejectEvenOneAdditionalHeadlessInstance() {
        let gui = BrowserProcess.Candidate(pid: 20, regular: true)
        let headless = BrowserProcess.Candidate(pid: 10, regular: false)
        XCTAssertTrue(BrowserProcess.permitsUnboundAction([gui]))
        XCTAssertFalse(BrowserProcess.permitsUnboundAction([gui, headless]))
        XCTAssertFalse(BrowserProcess.permitsUnboundAction([headless]))
        XCTAssertFalse(BrowserProcess.permitsUnboundAction([]))
    }

    func testPermissionAndEveryEventUseExactPIDWithoutPrompting() throws {
        let expected = NSAppleEventDescriptor(processIdentifier: 1234)
        var permissionAddress: NSAppleEventDescriptor?
        var sends = 0
        let reader = try ChromiumCapture(processID: 1234, permission: { address in
            permissionAddress = address
            return noErr
        }, send: { event, options in
            sends += 1
            let address = try XCTUnwrap(event.attributeDescriptor(forKeyword: keyAddressAttr))
            XCTAssertEqual(address.descriptorType, expected.descriptorType)
            XCTAssertEqual(address.data, expected.data)
            XCTAssertEqual(event.eventClass, AEEventClass(kAECoreSuite))
            XCTAssertEqual(event.eventID, AEEventID(kAEGetData))
            XCTAssertTrue(options.contains(.neverInteract))
            XCTAssertTrue(options.contains(.waitForReply))
            XCTAssertNotEqual(options.rawValue & UInt(kAEDoNotPromptForUserConsent), 0)
            return self.reply(.list())
        })
        XCTAssertEqual(permissionAddress?.data, expected.data)
        XCTAssertNil(try reader.activeTab())
        XCTAssertEqual(sends, 1)
    }

    func testConsentOrUnknownPermissionPreventsAllReads() {
        for status in [OSStatus(errAEEventNotPermitted), OSStatus(errAEEventWouldRequireUserConsent), OSStatus(procNotFound)] {
            XCTAssertThrowsError(try ChromiumCapture(processID: 1234, permission: { _ in status }, send: { _, _ in
                XCTFail("No event may follow a failed permission preflight")
                return self.reply(.null())
            }))
        }
    }

    func testPrivateAndUnknownModesNeverReadTabIdentityOrContent() throws {
        for mode in ["incognito", "unknown", ""] {
            let fixture = Fixture([ids(["window-A"]), NSAppleEventDescriptor(string: mode)])
            let reader = try capture(fixture)
            if mode == "incognito" { XCTAssertNil(try reader.activeTab()) }
            else { XCTAssertThrowsError(try reader.activeTab()) }
            XCTAssertEqual(fixture.properties, ["ID  ", "mode"])
        }
    }

    func testCapturePinsWindowAndTabBeforeReadingContent() throws {
        let fixture = Fixture([ids(["window-A", "window-B"]),
            NSAppleEventDescriptor(string: "normal"), NSAppleEventDescriptor(string: "tab-A"),
            NSAppleEventDescriptor(string: "https://fixture.example/"), NSAppleEventDescriptor(string: "Fixture")])
        let value = try capture(fixture).activeTab()
        XCTAssertEqual(value?.url, "https://fixture.example/")
        XCTAssertEqual(value?.title, "Fixture")
        XCTAssertEqual(fixture.properties, ["ID  ", "mode", "ID  ", "URL ", "pnam"])
        let checkedWindow = try XCTUnwrap(fixture.specifiers[1].forKeyword(AEKeyword(keyAEContainer)))
        assertUnique(checkedWindow, type: "cwin", id: "window-A")
        for specifier in fixture.specifiers.suffix(2) {
            let tab = try XCTUnwrap(specifier.forKeyword(AEKeyword(keyAEContainer)))
            assertUnique(tab, type: "CrTb", id: "tab-A")
            let window = try XCTUnwrap(tab.forKeyword(AEKeyword(keyAEContainer)))
            XCTAssertEqual(window.data, checkedWindow.data)
        }
        // Later reads cannot re-resolve window 1 after another window moves forward.
        XCTAssertEqual(checkedWindow.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue, OSType(formUniqueID))
    }

    func testActiveTabMetadataUsesCaptureWindowOrderWithoutReadingContent() throws {
        // The first ID is the target ChromiumCapture.activeTab() will read even
        // when a legacy AppleScript front-window observation would name another.
        let fixture = Fixture([ids(["capture-target", "legacy-front-window"]),
            NSAppleEventDescriptor(string: "normal"), NSAppleEventDescriptor(string: "canary-tab")])
        let metadata = try XCTUnwrap(capture(fixture).activeTabMetadata())

        XCTAssertEqual(metadata, ChromiumCapture.ActiveTabMetadata(
            windowID: "capture-target", mode: "normal", activeTabID: "canary-tab"))
        XCTAssertNotEqual(metadata.windowID, "legacy-front-window")
        XCTAssertEqual(fixture.properties, ["ID  ", "mode", "ID  "])
        XCTAssertFalse(fixture.properties.contains("URL "))
        XCTAssertFalse(fixture.properties.contains("pnam"))
    }

    func testActiveTabMetadataMismatchRefusesBeforeURLOrTitleReads() throws {
        let fixture = Fixture([ids(["capture-target", "expected-window"]),
            NSAppleEventDescriptor(string: "normal"), NSAppleEventDescriptor(string: "canary-tab")])
        let reader = try capture(fixture)
        let metadata = try XCTUnwrap(reader.activeTabMetadata())
        let targetMatches = metadata.windowID == "expected-window"
            && metadata.mode == "normal"
            && metadata.activeTabID == "canary-tab"

        XCTAssertFalse(targetMatches)
        XCTAssertEqual(fixture.properties, ["ID  ", "mode", "ID  "])
        XCTAssertFalse(fixture.properties.contains("URL "))
        XCTAssertFalse(fixture.properties.contains("pnam"))
    }

    func testWindowOrderChangeBetweenPreflightAndCaptureRefusesBeforeContentReads() throws {
        let fixture = Fixture([
            ids(["approved-window"]), NSAppleEventDescriptor(string: "normal"),
            NSAppleEventDescriptor(string: "approved-tab"),
            ids(["new-front-window", "approved-window"]), NSAppleEventDescriptor(string: "normal"),
            NSAppleEventDescriptor(string: "other-tab"),
            NSAppleEventDescriptor(string: "https://wrong.example/"), NSAppleEventDescriptor(string: "Wrong"),
        ])
        let reader = try capture(fixture)
        let approved = try XCTUnwrap(reader.activeTabMetadata())

        XCTAssertThrowsError(try reader.activeTab(matching: approved))
        XCTAssertEqual(fixture.properties, ["ID  ", "mode", "ID  ", "ID  ", "mode", "ID  "])
        XCTAssertFalse(fixture.properties.contains("URL "))
        XCTAssertFalse(fixture.properties.contains("pnam"))
    }

    func testIdentityBoundCaptureReadsContentFromApprovedPinnedTarget() throws {
        let fixture = Fixture([
            ids(["approved-window"]), NSAppleEventDescriptor(string: "normal"),
            NSAppleEventDescriptor(string: "approved-tab"),
            ids(["approved-window", "other-window"]), NSAppleEventDescriptor(string: "normal"),
            NSAppleEventDescriptor(string: "approved-tab"),
            NSAppleEventDescriptor(string: "https://fixture.example/"), NSAppleEventDescriptor(string: "Fixture"),
        ])
        let reader = try capture(fixture)
        let approved = try XCTUnwrap(reader.activeTabMetadata())

        let value = try reader.activeTab(matching: approved)

        XCTAssertEqual(value?.url, "https://fixture.example/")
        XCTAssertEqual(value?.title, "Fixture")
        XCTAssertEqual(fixture.properties, ["ID  ", "mode", "ID  ", "ID  ", "mode", "ID  ", "URL ", "pnam"])
        let contentTab = try XCTUnwrap(fixture.specifiers.suffix(2).first?.forKeyword(AEKeyword(keyAEContainer)))
        let contentWindow = try XCTUnwrap(contentTab.forKeyword(AEKeyword(keyAEContainer)))
        assertUnique(contentWindow, type: "cwin", id: "approved-window")
    }

    func testPrivateActiveTabMetadataDoesNotReadTabIdentityOrContent() throws {
        let fixture = Fixture([ids(["private-window", "normal-window"]),
            NSAppleEventDescriptor(string: "incognito")])
        let metadata = try XCTUnwrap(capture(fixture).activeTabMetadata())

        XCTAssertEqual(metadata, ChromiumCapture.ActiveTabMetadata(
            windowID: "private-window", mode: "incognito", activeTabID: nil))
        XCTAssertEqual(fixture.properties, ["ID  ", "mode"])
    }

    func testInventorySkipsPrivateWindowBeforeEnumeratingItsTabs() throws {
        let fixture = Fixture([ids(["private", "normal"]),
            NSAppleEventDescriptor(string: "incognito"), NSAppleEventDescriptor(string: "normal"),
            ids(["public-tab"]), NSAppleEventDescriptor(string: "https://fixture.example/"),
            NSAppleEventDescriptor(string: "Fixture")])
        let tabs = try capture(fixture).inventory(browser: .chrome)
        XCTAssertEqual(tabs, [BrowserTab(browser: .chrome, window: 2, index: 1,
            url: "https://fixture.example/", title: "Fixture")])
        XCTAssertEqual(fixture.properties, ["ID  ", "mode", "mode", "ID  ", "URL ", "pnam"])
        for specifier in fixture.specifiers.suffix(2) {
            let tab = try XCTUnwrap(specifier.forKeyword(AEKeyword(keyAEContainer)))
            let window = try XCTUnwrap(tab.forKeyword(AEKeyword(keyAEContainer)))
            assertUnique(window, type: "cwin", id: "normal")
        }
    }

    func testNumericWindowAndTabIDsKeepTheirDescriptorType() throws {
        let windowIDs = NSAppleEventDescriptor.list()
        windowIDs.insert(NSAppleEventDescriptor(int32: 42), at: 1)
        let tabIDs = NSAppleEventDescriptor.list()
        tabIDs.insert(NSAppleEventDescriptor(int32: 81), at: 1)
        let fixture = Fixture([windowIDs, NSAppleEventDescriptor(string: "normal"), tabIDs,
            NSAppleEventDescriptor(string: "https://fixture.example/"),
            NSAppleEventDescriptor(string: "Fixture")])
        let tabs = try capture(fixture).inventory(browser: .chrome)
        XCTAssertEqual(tabs.count, 1)
        for specifier in fixture.specifiers.suffix(2) {
            let tab = try XCTUnwrap(specifier.forKeyword(AEKeyword(keyAEContainer)))
            let window = try XCTUnwrap(tab.forKeyword(AEKeyword(keyAEContainer)))
            let windowID = try XCTUnwrap(window.forKeyword(AEKeyword(keyAEKeyData)))
            let tabID = try XCTUnwrap(tab.forKeyword(AEKeyword(keyAEKeyData)))
            XCTAssertEqual(windowID.descriptorType, typeSInt32)
            XCTAssertEqual(windowID.int32Value, 42)
            XCTAssertEqual(tabID.descriptorType, typeSInt32)
            XCTAssertEqual(tabID.int32Value, 81)
        }
    }

    func testUnknownModeAndMalformedInventoryFailInsteadOfReturningEmptyList() throws {
        for values in [[NSAppleEventDescriptor.null()],
                       [ids(["window"]), NSAppleEventDescriptor(string: "unknown")],
                       [ids(["window"]), NSAppleEventDescriptor(string: "normal"), NSAppleEventDescriptor.null()]] {
            let fixture = Fixture(values)
            XCTAssertThrowsError(try capture(fixture).inventory(browser: .chrome))
            XCTAssertFalse(fixture.properties.contains("URL "))
            XCTAssertFalse(fixture.properties.contains("pnam"))
        }
    }

    func testSendFailureAndRevokedConsentRemainExplicitFailures() throws {
        for code in [Int(errAETimeout), Int(errAEEventWouldRequireUserConsent)] {
            let reader = try ChromiumCapture(processID: 1234, permission: { _ in noErr }, send: { _, _ in
                throw NSError(domain: NSOSStatusErrorDomain, code: code)
            })
            XCTAssertThrowsError(try reader.inventory(browser: .chrome)) { error in
                XCTAssertEqual(error as? ChromiumCapture.Failure,
                    code == Int(errAETimeout) ? .unavailable : .needsConsent)
            }
        }
    }

    private final class Fixture {
        var values: [NSAppleEventDescriptor]
        var properties: [String] = []
        var specifiers: [NSAppleEventDescriptor] = []
        init(_ values: [NSAppleEventDescriptor]) { self.values = values }
    }

    private func capture(_ fixture: Fixture) throws -> ChromiumCapture {
        try ChromiumCapture(processID: 1234, permission: { _ in noErr }, send: { event, _ in
            let specifier = try XCTUnwrap(event.paramDescriptor(forKeyword: keyDirectObject))
            fixture.specifiers.append(specifier)
            let code = try XCTUnwrap(specifier.forKeyword(AEKeyword(keyAEKeyData))).typeCodeValue
            let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }
            fixture.properties.append(String(bytes: bytes, encoding: .ascii)!)
            guard !fixture.values.isEmpty else {
                XCTFail("Unexpected content read")
                throw ChromiumCapture.Failure.unavailable
            }
            return self.reply(fixture.values.removeFirst())
        })
    }

    private func ids(_ values: [String]) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        for (index, value) in values.enumerated() {
            list.insert(NSAppleEventDescriptor(string: value), at: index + 1)
        }
        return list
    }

    private func reply(_ value: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let reply = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEAnswer), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        reply.setParam(value, forKeyword: keyDirectObject)
        return reply
    }

    private func assertUnique(_ object: NSAppleEventDescriptor, type: String, id: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(object.descriptorType, typeObjectSpecifier, file: file, line: line)
        XCTAssertEqual(object.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue,
                       ChromiumCapture.code(type), file: file, line: line)
        XCTAssertEqual(object.forKeyword(AEKeyword(keyAEKeyForm))?.enumCodeValue, OSType(formUniqueID), file: file, line: line)
        XCTAssertEqual(object.forKeyword(AEKeyword(keyAEKeyData))?.stringValue, id, file: file, line: line)
    }
}
