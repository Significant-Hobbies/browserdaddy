import Combine

@MainActor final class AppUpdates: DaddyAppUpdates {
    init() { super.init(appName: "BrowserDaddy", busyMessage: "Finish the current history sync before checking for updates.") }

    func start(model: AppModel) {
        start(observing: model.objectWillChange.eraseToAnyPublisher()) { [weak model] in
            guard let model else { return false }
            return !model.extracting && !model.classifying
        }
    }
}
