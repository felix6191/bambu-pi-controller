// BambuControllerApp.swift - App entry point with onboarding gate
import SwiftUI

@main
struct BambuControllerApp: App {
    @StateObject private var appState = AppState.shared
    @State private var onboarded: Bool

    init() {
        // Tutorial noch nicht abgeschlossen? Dann beim frischen Start alles
        // zurücksetzen: Pi neu suchen, neu verbinden, Drucker neu einrichten.
        if !AppSettings.shared.onboarded {
            AppSettings.resetForFreshOnboarding()
        }
        _onboarded = State(initialValue: AppSettings.shared.onboarded)
    }

    var body: some Scene {
        WindowGroup {
            if onboarded && !needsSetup {
                ContentView()
                    .environmentObject(appState)
            } else {
                SetupFlowView(finished: $onboarded)
                    .onChange(of: onboarded) { _, v in
                        guard v else { return }
                        // After onboarding, boot the live/demo connection once
                        Task { @MainActor in
                            if AppSettings.shared.demoMode {
                                PrinterViewModel.shared.enableDemo()
                            } else {
                                await PrinterViewModel.shared.refreshCapabilities()
                                await PrinterViewModel.shared.loadStatus()
                            }
                        }
                    }
            }
        }
    }

    /// Bestandskunden mit leerer Config (altes Onboarding) sehen den neuen
    /// Auto-Flow statt eines leeren Dashboards mit Tippfeldern.
    private var needsSetup: Bool {
        let s = AppSettings.shared
        return !s.demoMode && (s.serverURL.isEmpty || s.apiToken.isEmpty)
    }
}
