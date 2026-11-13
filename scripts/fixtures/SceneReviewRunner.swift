import Foundation
import Darwin

@main
struct SceneReviewRunner {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else { exit(64) }
        let app = URL(fileURLWithPath: arguments[1], isDirectory: true)
        guard Bundle(url: app)?.bundleIdentifier?.hasPrefix("com.significanthobbies.browserdaddy.scene-review.") == true else {
            exit(78)
        }
        let output = URL(fileURLWithPath: arguments[3], isDirectory: true)
        guard ["ready.json", "done", "finished.json"].allSatisfy({
            !FileManager.default.fileExists(atPath: output.appendingPathComponent($0).path)
        }) else { exit(78) }
        let child = Process()
        let completion = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in completion.signal() }
        child.executableURL = app.appendingPathComponent("Contents/MacOS/BrowserDaddySceneReview")
        child.arguments = ["--fixture-home", arguments[2], "--fixture-output", arguments[3]]
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = arguments[2]
        child.environment = environment
        try child.run()
        if completion.wait(timeout: .now() + 130) == .timedOut {
            if child.isRunning { child.terminate() }
            if completion.wait(timeout: .now() + 5) == .timedOut, child.isRunning {
                kill(child.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 5)
            }
            exit(1)
        }
        guard child.terminationReason == .exit, child.terminationStatus == 0 else { exit(1) }
        let finished = output.appendingPathComponent("finished.json")
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: finished)) as? [String: Any]
        guard state?["successful"] as? Bool == true, state?["isolationVerified"] as? Bool == true,
              state?["fixtureCleanupCompleted"] as? Bool == true,
              state?["sceneReady"] as? Bool == true, state?["previewStateConfirmed"] as? Bool == true,
              state?["nativePreferencesLoads"] as? Int == 0, state?["nativePreferencesApplies"] as? Int == 0,
              state?["blockingEnabled"] as? Bool == false else { exit(1) }
        print("Standalone scene child exit and isolation verified")
    }
}
