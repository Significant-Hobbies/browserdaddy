import AppKit
import SwiftUI

/// BrowserDaddy's own Tab Scout identity; compact mark and full illustration.
struct DaddyArtwork: View {
    var brand = false
    private static let mark = DaddyResources.url(forResource: "BrowserDaddyIcon")
        .flatMap(NSImage.init(contentsOf:))
    private static let sheet = DaddyResources.url(forResource: "BrowserDaddyScout")
        .flatMap(NSImage.init(contentsOf:))
    var body: some View {
        GeometryReader { geometry in
            if brand, let image = Self.mark {
                Image(nsImage: image).resizable().scaledToFit()
            } else if let image = Self.sheet {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            }
        }.clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}

private class DaddyResourceAnchor {}

enum DaddyResources {
    static func url(forResource nameForArtwork: String) -> URL? {
        let name = "BrowserDaddy_BrowserDaddy.bundle"
        var locations = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle(for: DaddyResourceAnchor.self).resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent(name)
        ]
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
            ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"] {
            locations.insert(URL(fileURLWithPath: path).appendingPathComponent(name), at: 0)
        }
        #endif
        return locations.compactMap { $0 }.compactMap { Bundle(url: $0) }
            .compactMap { $0.url(forResource: nameForArtwork, withExtension: "png") }.first
    }
}
