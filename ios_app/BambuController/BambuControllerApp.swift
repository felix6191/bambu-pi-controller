//  BambuControllerApp.swift
//  BambuController
//
//  Created for Bambu Lab A1 remote control via Raspberry Pi

import SwiftUI

@main
struct BambuControllerApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
        }
    }
}