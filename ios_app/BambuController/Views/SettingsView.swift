// SettingsView.swift - App settings and configuration
import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var showToken = false
    @State private var testResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Server Verbindung") {
                    TextField("Server URL (z.B. http://100.x.x.x:8000)", text: $settings.serverURL).textInputAutocapitalization(.never).autocorrectionDisabled().onChange(of: settings.serverURL) { settings.commit(); WebSocketService.shared.disconnect(); if settings.autoConnect { WebSocketService.shared.connect() } }
                    HStack {
                        Text("API Token"); Spacer()
                        if showToken { TextField("Token", text: $settings.apiToken).textInputAutocapitalization(.never).autocorrectionDisabled() }
                        else { SecureField("Token", text: $settings.apiToken).textInputAutocapitalization(.never).autocorrectionDisabled() }
                        Button { showToken.toggle() } label: { Image(systemName: showToken ? "eye.slash" : "eye") }
                    }.onChange(of: settings.apiToken) { settings.commit(); WebSocketService.shared.disconnect(); if settings.autoConnect { WebSocketService.shared.connect() } }
                    Toggle("Tailscale verwenden", isOn: $settings.useTailscale).onChange(of: settings.useTailscale) { settings.commit() }
                    Toggle("Auto-Verbinden", isOn: $settings.autoConnect).onChange(of: settings.autoConnect) { settings.commit() }
                }
                Section {
                    Button("Verbindung testen") { testConnection() }.disabled(settings.serverURL.isEmpty || settings.apiToken.isEmpty)
                    if let r = testResult { Text(r).font(.caption).foregroundColor(r.contains("Erfolg") ? .green : .red) }
                }
                Section("Info") {
                    HStack { Text("Version"); Spacer(); Text("1.0.0").foregroundColor(.secondary) }
                    Link("GitHub Repository", destination: URL(string: "https://github.com")!)
                    Link("Bambu Lab A1 Docs", destination: URL(string: "https://bambulab.com")!)
                }
                Section { Button("Cache leeren", role: .destructive) { URLCache.shared.removeAllCachedResponses(); testResult = "Cache geleert" } }
            }.navigationTitle("Einstellungen")
        }
    }

    private func testConnection() {
        testResult = "Teste..."
        Task {
            do {
                let url = URL(string: "\(settings.baseURL)/health")!
                var req = URLRequest(url: url); req.setValue("Bearer \(settings.apiToken)", forHTTPHeaderField: "Authorization")
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 { testResult = "✅ Erfolgreich verbunden" }
                else { testResult = "❌ Server antwortet nicht korrekt" }
            } catch { testResult = "❌ \(error.localizedDescription)" }
        }
    }
}

#Preview("Settings") { SettingsView() }