// ContentView.swift - Main tab view
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = PrinterViewModel.shared

    var body: some View {
        TabView {
            DashboardView().tabItem { Label("Dashboard", systemImage: "house.fill") }
            ControlsView().tabItem { Label("Steuerung", systemImage: "slider.horizontal.3") }
            CameraView().tabItem { Label("Kamera", systemImage: "camera.fill") }
            SettingsView().tabItem { Label("Einstellungen", systemImage: "gearshape.fill") }
        }
        .accentColor(.bambuBlue)
        .onAppear { Task { await vm.loadStatus() } }
    }
}