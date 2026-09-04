// BambuControllerApp.swift - App entry point
import SwiftUI

@main
struct BambuControllerApp: App {
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(appState).preferredColorScheme(.dark)
        }
    }
}