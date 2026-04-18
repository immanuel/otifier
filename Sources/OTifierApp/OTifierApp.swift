import SwiftUI

@main
struct OTifierApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            OTifierMenu(state: appState)
        } label: {
            Image(systemName: "rectangle.and.pencil.and.ellipsis")
        }
        .menuBarExtraStyle(.window)
    }
}
