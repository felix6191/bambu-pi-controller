// ContentView.swift - Main tab view
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var vm = PrinterViewModel.shared
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            DashboardView().tabItem { Label("Dashboard", systemImage: "house.fill") }.tag(0)
            FilesView().tabItem { Label("Dateien", systemImage: "doc.fill") }.tag(1)
            ControlsView().tabItem { Label("Steuerung", systemImage: "slider.horizontal.3") }.tag(2)
            CameraView().tabItem { Label("Kamera", systemImage: "camera.fill") }.tag(3)
            SettingsView().tabItem { Label("Einstellungen", systemImage: "gearshape.fill") }.tag(4)
        }
        .tint(AppTheme.accent)
        .sensoryFeedback(.selection, trigger: tab)
        .onAppear { Task { await vm.loadStatus() } }
    }
}