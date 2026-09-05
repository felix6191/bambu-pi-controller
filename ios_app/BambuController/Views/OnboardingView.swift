// OnboardingView.swift - Guided first-run setup with demo mode.
import SwiftUI

struct OnboardingView: View {
    @Binding var finished: Bool
    @State private var step = 0
    @State private var settings = AppSettings.shared
    @State private var showToken = false
    @State private var testResult: String?
    @State private var testing = false
    @State private var showWherePrinter = false
    @State private var showWhereToken = false

    private let totalSteps = 4

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: Double(step + 1), total: Double(totalSteps))
                    .progressViewStyle(LinearProgressViewStyle(tint: AppTheme.accent))
                    .padding(.horizontal).padding(.top, 8)

                TabView(selection: $step) {
                    welcomePage.tag(0)
                    printerPage.tag(1)
                    serverPage.tag(2)
                    finishPage.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: step)

                navBar
            }
            .navigationTitle("Einrichtung")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Nav

    private var navBar: some View {
        HStack {
            if step > 0 {
                Button("Zurück") { withAnimation { step -= 1 } }
                    .buttonStyle(.bordered)
            }
            Spacer()
            if step < totalSteps - 1 {
                Button("Weiter") { withAnimation { step += 1 } }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.accent)
                    .disabled(!stepValid)
            }
        }
        .padding()
    }

    private var stepValid: Bool {
        switch step {
        case 1: return true // printer data optional (demo possible)
        case 2: return settings.demoWanted ? true : (!settings.serverURL.isEmpty && !settings.apiToken.isEmpty)
        default: return true
        }
    }

    // MARK: - Pages

    private var welcomePage: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "printer.filled.and.paper")
                    .font(.system(size: 72))
                    .foregroundColor(AppTheme.accent)
                    .padding(.top, 24)
                Text("BambuController")
                    .font(.largeTitle).fontWeight(.bold)
                Text("Dein Bambu Lab A1 — von überall im Blick und unter Kontrolle.")
                    .font(.body).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                VStack(spacing: 12) {
                    FeatureRow(icon: "server.rack", title: "Raspberry Pi als Brücke", text: "Der Pi spricht direkt mit deinem Drucker im Heimnetz (MQTT, TLS).")
                    FeatureRow(icon: "lock.shield.fill", title: "Weltweit & sicher", text: "Per Tailscale-VPN erreichst du den Pi von überall — ohne Portfreigaben.")
                    FeatureRow(icon: "gauge.with.dots.needle.33percent", title: "Live & Steuerung", text: "Temperaturen, Fortschritt, Pause/Stopp, Speed-Modi, Licht und Kamera.")
                }
                .padding(.horizontal)
            }
        }
    }

    private var printerPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("1 · Drucker").font(.caption).fontWeight(.bold).foregroundColor(AppTheme.accent)
                Text("Bambu Lab A1 verbinden").font(.title2).fontWeight(.bold)
                HintText(text: "Diese Daten trägt der Installer auf dem Pi ein — hier brauchst du sie nur, wenn du die Verbindung verstehen oder prüfen willst. Für die Demo kannst du alles leer lassen.")
                Group {
                    Text("Drucker-IP (Heimnetz)").font(.subheadline).fontWeight(.semibold)
                    TextField("z. B. 192.168.1.50", text: $settings.printerIPHint)
                        .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.decimalPad)
                    Text("Seriennummer").font(.subheadline).fontWeight(.semibold)
                    TextField("z. B. 01S00A…", text: $settings.printerSerialHint)
                        .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("LAN Access Code").font(.subheadline).fontWeight(.semibold)
                    TextField("8-stelliger Code", text: $settings.printerCodeHint)
                        .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Button("Wo finde ich diese Daten?") { showWherePrinter = true }
                    .font(.footnote)
                    .sheet(isPresented: $showWherePrinter) {
                        HelpSheet(title: "Druckerdaten finden", lines: [
                            "1. Am A1: Einstellungen → Netzwerk → LAN-Zugriff / Access Code anzeigen.",
                            "2. Seriennummer: Aufkleber am Drucker oder Originalverpackung.",
                            "3. Drucker-IP: Am Display unter Netzwerk — oder in der Bambu Handy App.",
                            "4. Wichtig: Entwicklermodus bzw. LAN-Modus am Drucker aktivieren.",
                        ])
                    }
            }.padding()
        }
    }

    private var serverPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("2 · Server (Raspberry Pi)").font(.caption).fontWeight(.bold).foregroundColor(AppTheme.accent)
                Text("Mit dem Pi verbinden").font(.title2).fontWeight(.bold)
                HintText(text: "Der Pi läuft als dein persönlicher Cloud-Ersatz. Zuhause nimmst du die Heimnetz-IP, von unterwegs die Tailscale-IP (100.x.x.x).")
                Text("Server-URL").font(.subheadline).fontWeight(.semibold)
                TextField("http://100.x.x.x:8000", text: $settings.serverURL)
                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL)
                Text("API-Token").font(.subheadline).fontWeight(.semibold)
                HStack {
                    Group {
                        if showToken { TextField("Token vom Pi", text: $settings.apiToken) }
                        else { SecureField("Token vom Pi", text: $settings.apiToken) }
                    }
                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button { showToken.toggle() } label: { Image(systemName: showToken ? "eye.slash" : "eye") }
                }
                Button("Woher kommt der Token?") { showWhereToken = true }
                    .font(.footnote)
                    .sheet(isPresented: $showWhereToken) {
                        HelpSheet(title: "API-Token finden", lines: [
                            "Der Installer zeigt den Token am Ende der Installation an.",
                            "Später: auf dem Pi in /opt/bambu-pi-controller/pi_backend/.env nachsehen (API_TOKEN).",
                            "Token geheim halten — er schützt den Zugriff auf deinen Drucker.",
                        ])
                    }
                Button {
                    testConnection()
                } label: {
                    if testing { ProgressView().frame(maxWidth: .infinity) }
                    else { Text("Verbindung testen").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent).tint(AppTheme.accent)
                .disabled(settings.serverURL.isEmpty || settings.apiToken.isEmpty || testing)
                if let r = testResult {
                    Text(r).font(.footnote).foregroundColor(r.hasPrefix("✅") ? .green : .red)
                }
            }.padding()
        }
    }

    private var finishPage: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("3 · Los geht's").font(.caption).fontWeight(.bold).foregroundColor(AppTheme.accent)
                Text("Bereit?").font(.largeTitle).fontWeight(.bold)
                ModeCard(
                    icon: "play.circle.fill", title: "Demo ausprobieren",
                    text: "Simulierter A1 mit Live-Temperaturen und laufendem Druck. Ideal zum Kennenlernen — keine Hardware nötig.",
                    selected: settings.demoWanted
                ) { settings.demoWanted = true }
                ModeCard(
                    icon: "antenna.radiowaves.left.and.right", title: "Echten Drucker verbinden",
                    text: settings.serverURL.isEmpty ? "Noch keine Server-URL eingetragen — du kannst sie später in den Einstellungen nachtragen." : "Server: \(settings.serverURL)",
                    selected: !settings.demoWanted
                ) { settings.demoWanted = false }
                Button("Fertig — zur App") { finish() }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 8)
                HintText(text: "Du kannst jederzeit in den Einstellungen zwischen Demo und echtem Drucker wechseln oder das Setup erneut durchlaufen.")
            }.padding()
        }
    }

    // MARK: - Actions

    private func testConnection() {
        testing = true; testResult = nil
        let url = settings.serverURL.hasSuffix("/") ? String(settings.serverURL.dropLast()) : settings.serverURL
        Task {
            do {
                guard let endpoint = URL(string: url + "/health") else { throw URLError(.badURL) }
                var req = URLRequest(url: endpoint, timeoutInterval: 12)
                req.setValue("Bearer \(settings.apiToken)", forHTTPHeaderField: "Authorization")
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    testResult = "✅ Pi erreichbar — weiter geht's."
                } else { testResult = "❌ Server antwortet, aber mit Fehler. Token prüfen." }
            } catch {
                testResult = "❌ Nicht erreichbar: \(error.localizedDescription)"
            }
            testing = false
        }
    }

    private func finish() {
        settings.onboarded = true
        settings.demoMode = settings.demoWanted
        settings.commit()
        finished = true
    }
}

// MARK: - Subviews

private struct FeatureRow: View {
    let icon, title, text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundColor(AppTheme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding().card()
    }
}

private struct ModeCard: View {
    let icon, title, text: String
    let selected: Bool
    let tap: () -> Void
    var body: some View {
        Button(action: tap) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.largeTitle).foregroundColor(selected ? AppTheme.accent : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundColor(.primary)
                    Text(text).font(.subheadline).foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? AppTheme.accent : .secondary)
            }
            .padding()
            .overlay(RoundedRectangle(cornerRadius: AppTheme.cardRadius).stroke(selected ? AppTheme.accent : Color(.systemGray4), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }
}

private struct HelpSheet: View {
    let title: String
    let lines: [String]
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            List(lines, id: \.self) { Text($0) }
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Fertig") { dismiss() } } }
        }
    }
}

#Preview { OnboardingView(finished: .constant(false)) }
