// BambuControllerApp.swift - App entry point with onboarding gate
import SwiftUI

@main
struct BambuControllerApp: App {
    @StateObject private var appState = AppState.shared
    @State private var onboarded = AppSettings.shared.onboarded

    var body: some Scene {
        WindowGroup {
            if onboarded {
                ContentView()
                    .environmentObject(appState)
                    .preferredColorScheme(.dark)
            } else {
                OnboardingView(finished: $onboarded)
                    .preferredColorScheme(.dark)
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
}
