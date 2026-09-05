// SettingsView.swift - App settings, connection status, demo & onboarding
import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var showToken = false
    @State private var testResult: String?
    @State private var testing = false
    @State private var showOnboarding = false
    @State private var showResetConfirm = false
    @ObservedObject private var vm = PrinterViewModel.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        ConnectionDot(ok: connectionOK)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connectionTitle).font(.headline)
                            Text(connectionSubtitle).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if vm.isDemo { Pill(text: "DEMO", color: .purple) }
                    }
                } header: { Text("Status") }

                Section {
                    TextField("http://100.x.x.x:8000", text: $settings.serverURL)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .onChange(of: settings.serverURL) { _, _ in commit() }
                    HStack {
                        Text("API-Token")
                        Spacer()
                        Group {
                            if showToken { TextField("Token", text: $settings.apiToken) }
                            else { SecureField("Token", text: $settings.apiToken) }
                        }
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button { showToken.toggle() } label: { Image(systemName: showToken ? "eye.slash" : "eye") }
                            .touchTarget()
                            .accessibilityLabel(showToken ? "Token verbergen" : "Token anzeigen")
                    }
                    .onChange(of: settings.apiToken) { _, _ in commit() }
                    Toggle("Tailscale unterwegs nutzen", isOn: $settings.useTailscale)
                        .onChange(of: settings.useTailscale) { _, _ in commit() }
                    Toggle("Automatisch verbinden", isOn: $settings.autoConnect)
                        .onChange(of: settings.autoConnect) { _, _ in commit() }
                } header: {
                    Text("Server (Raspberry Pi)")
                } footer: {
                    HintText(text: "Zuhause: Heimnetz-IP des Pi. Unterwegs: Tailscale-IP (100.x.x.x). Der Token steht am Ende der Pi-Installation bzw. in /opt/bambu-pi-controller/pi_backend/.env.")
                }

                Section {
                    Button { testConnection() } label: {
                        if testing { ProgressView().frame(maxWidth: .infinity) }
                        else { Text("Verbindung testen").frame(maxWidth: .infinity) }
                    }
                    .disabled(settings.serverURL.isEmpty || settings.apiToken.isEmpty || testing || vm.isDemo)
                    if let r = testResult {
                        Text(r).font(.footnote).foregroundColor(r.hasPrefix("✅") ? .green : .red)
                    }
                }

                Section {
                    Toggle("Demo-Modus (simulierter Drucker)", isOn: Binding(
                        get: { settings.demoMode },
                        set: { v in settings.demoMode = v; commit(); v ? vm.enableDemo() : vm.disableDemo() }
                    ))
                    .tint(.purple)
                    Button("Einrichtung erneut durchlaufen") { showOnboarding = true }
                } header: {
                    Text("Modus")
                } footer: {
                    HintText(text: "Im Demo-Modus siehst du einen simulierten A1 — ideal zum Ausprobieren ohne Hardware.")
                }

                Section("Drucker (Bambu Lab A1, offiziell)") {
                    LabeledValue(label: "Düse max.", value: "\(vm.limits.maxNozzleTemp) °C")
                    LabeledValue(label: "Bett max.", value: "\(vm.limits.maxBedTemp) °C")
                    LabeledValue(label: "Bauraum", value: "256 × 256 × 256 mm")
                    LabeledValue(label: "Düse", value: "0,4 mm Edelstahl")
                    if let s = vm.status, !s.nozzleDiameter.isEmpty {
                        LabeledValue(label: "Gemeldet", value: "Ø \(s.nozzleDiameter) mm · SD: \(s.sdcard ? "ok" : "fehlt")")
                    }
                }

                Section("Info") {
                    LabeledValue(label: "Version", value: "1.0.0")
                    Link("Offizielle A1-Spezifikationen ↗", destination: URL(string: "https://bambulab.com/en/a1/tech-specs")!)
                    Button("Cache leeren", role: .destructive) {
                        URLCache.shared.removeAllCachedResponses()
                        testResult = "Cache geleert."
                    }
                    Button("Alle Einstellungen zurücksetzen", role: .destructive) { showResetConfirm = true }
                        .alert("Wirklich zurücksetzen?", isPresented: $showResetConfirm) {
                            Button("Abbrechen", role: .cancel) {}
                            Button("Zurücksetzen", role: .destructive) { resetAll() }
                        }
                }
            }
            .navigationTitle("Einstellungen")
            .fullScreenCover(isPresented: $showOnboarding) {
                ReOnboardingHost()
            }
            .onAppear { settings = AppSettings.shared }
        }
    }

    // MARK: - Status

    private var connectionOK: Bool {
        if vm.isDemo { return true }
        return vm.status != nil
    }
    private var connectionTitle: String {
        if vm.isDemo { return "Demo-Drucker aktiv" }
        return vm.status != nil ? "Verbunden" : "Nicht verbunden"
    }
    private var connectionSubtitle: String {
        if vm.isDemo { return "Simulierter Bambu Lab A1" }
        if settings.serverURL.isEmpty { return "Keine Server-URL eingetragen" }
        return settings.serverURL
    }

    // MARK: - Actions

    private func commit() {
        settings.commit()
        WebSocketService.shared.disconnect()
        if settings.autoConnect && !settings.demoMode { WebSocketService.shared.connect() }
    }

    private func testConnection() {
        testing = true; testResult = nil
        let url = settings.baseURL
        Task {
            do {
                guard let endpoint = URL(string: url + "/health") else { throw URLError(.badURL) }
                var req = URLRequest(url: endpoint, timeoutInterval: 12)
                req.setValue("Bearer \(settings.apiToken)", forHTTPHeaderField: "Authorization")
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    testResult = "✅ Pi erreichbar."
                    await vm.refreshCapabilities()
                    await vm.loadStatus()
                } else { testResult = "❌ Server antwortet mit Fehler — Token prüfen." }
            } catch {
                testResult = "❌ Nicht erreichbar: \(error.localizedDescription)"
            }
            testing = false
        }
    }

    private func resetAll() {
        UserDefaults.standard.removeObject(forKey: "AppSettings")
        AppSettings.shared = AppSettings()
        settings = AppSettings.shared
        testResult = "Zurückgesetzt. Bitte Setup erneut durchlaufen."
    }
}

private struct LabeledValue: View {
    let label, value: String
    var body: some View {
        HStack { Text(label); Spacer(); Text(value).foregroundColor(.secondary) }
    }
}

private struct ConnectionDot: View {
    let ok: Bool
    var body: some View {
        Circle().fill(ok ? Color.green : Color.red).frame(width: 12, height: 12)
    }
}

/// Re-runs onboarding from settings without touching the main gate
private struct ReOnboardingHost: View {
    @Environment(\.dismiss) var dismiss
    @State private var done = false
    var body: some View {
        OnboardingView(finished: $done)
            .onChange(of: done) { _, v in if v { dismiss() } }
    }
}

#Preview("Settings") { SettingsView() }
