import SwiftUI

@main
struct OTifierApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var updater = UpdaterController()

    var body: some Scene {
        MenuBarExtra {
            OTifierMenu(state: appState, updater: updater)
        } label: {
            Image(systemName: "rectangle.and.pencil.and.ellipsis")
        }
        .menuBarExtraStyle(.window)
    }
}
