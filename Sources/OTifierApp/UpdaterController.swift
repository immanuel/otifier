import Sparkle
import SwiftUI

@MainActor
final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.automaticallyChecksForUpdates = true
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
