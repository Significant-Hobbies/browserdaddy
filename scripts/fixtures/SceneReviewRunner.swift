import Foundation

@main
struct SceneReviewRunner {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else { exit(64) }
        let app = URL(fileURLWithPath: arguments[1], isDirectory: true)
        guard Bundle(url: app)?.bundleIdentifier?.hasPrefix("com.significanthobbies.browserdaddy.scene-review.") == true else {
            exit(78)
        }
        let child = Process()
        child.executableURL = app.appendingPathComponent("Contents/MacOS/BrowserDaddySceneReview")
        child.arguments = ["--fixture-home", arguments[2], "--fixture-output", arguments[3]]
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = arguments[2]
        child.environment = environment
        try child.run()
        child.waitUntilExit()
        guard child.terminationReason == .exit, child.terminationStatus == 0 else { exit(1) }
        let finished = URL(fileURLWithPath: arguments[3], isDirectory: true).appendingPathComponent("finished.json")
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: finished)) as? [String: Any]
        guard state?["successful"] as? Bool == true, state?["isolationVerified"] as? Bool == true,
              state?["fixtureCleanupCompleted"] as? Bool == true,
              state?["nativePreferencesLoads"] as? Int == 0, state?["nativePreferencesApplies"] as? Int == 0,
              state?["blockingEnabled"] as? Bool == false else { exit(1) }
        print("Standalone scene child exit and isolation verified")
    }
}
