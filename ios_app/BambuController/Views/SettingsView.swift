//  SettingsView.swift
//  BambuController
//
//  App settings and configuration

import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var showToken = false
    @State private var testResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Server Verbindung") {
                    TextField("Server URL (z.B. http://100.x.x.x:8000)", text: $settings.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: settings.serverURL) { _ in settings.save() }

                    HStack {
                        Text("API Token")
                        Spacer()
                        if showToken {
                            TextField("Token", text: $settings.apiToken)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("Token", text: $settings.apiToken)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                        Button(action: { showToken.toggle() }) {
                            Image(systemName: showToken ? "eye.slash" : "eye")
                        }
                    }
                    .onChange(of: settings.apiToken) { _ in settings.save() }

                    Toggle("Tailscale verwenden", isOn: $settings.useTailscale)
                        .onChange(of: settings.useTailscale) { _ in settings.save() }

                    Toggle("Auto-Verbinden", isOn: $settings.autoConnect)
                        .onChange(of: settings.autoConnect) { _ in settings.save() }
                }

                Section {
                    Button("Verbindung testen") {
                        testConnection()
                    }
                    .disabled(settings.serverURL.isEmpty || settings.apiToken.isEmpty)

                    if let result = testResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(result.contains("Erfolg") ? .green : .red)
                    }
                }

                Section("Info") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }

                    Link("GitHub Repository", destination: URL(string: "https://github.com")!)
                    Link("Bambu Lab A1 Docs", destination: URL(string: "https://bambulab.com")!)
                }

                Section {
                    Button("Cache leeren", role: .destructive) {
                        clearCache()
                    }
                }
            }
            .navigationTitle("Einstellungen")
        }
    }

    private func testConnection() {
        testResult = "Teste..."

        Task {
            do {
                let url = URL(string: "\(settings.baseURL)/health")!
                var request = URLRequest(url: url)
                request.setValue("Bearer \(settings.apiToken)", forHTTPHeaderField: "Authorization")

                let (data, response) = try await URLSession.shared.data(for: request)

                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200 {
                    testResult = "✅ Erfolgreich verbunden"
                } else {
                    testResult = "❌ Server antwortet nicht korrekt"
                }
            } catch {
                testResult = "❌ \(error.localizedDescription)"
            }
        }
    }

    private func clearCache() {
        URLCache.shared.removeAllCachedResponses()
        testResult = "Cache geleert"
    }
}

#Preview("Settings") {
    SettingsView()
}