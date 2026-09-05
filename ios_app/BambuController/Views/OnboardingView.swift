// OnboardingView.swift - Guided first-run setup with demo mode.
import SwiftUI

struct OnboardingView: View {
    @Binding var finished: Bool
    @State private var step = 0
    @State private var settings = AppSettings.shared
    @State private var showToken = false
    @State private var testResult: String?
    @State private var testing = false
    @State private var showWhereToken = false
    @State private var showWherePrinter = false
    @State private var printerHost = ""
    @State private var printerSerial = ""
    @State private var printerCode = ""
    @State private var printerResult: String?
    @State private var printerOK: Bool?
    @State private var printerSending = false

    private let totalSteps = 5

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: Double(step + 1), total: Double(totalSteps))
                    .progressViewStyle(LinearProgressViewStyle(tint: AppTheme.accent))
                    .padding(.horizontal).padding(.top, 8)

                TabView(selection: $step) {
                    welcomePage.tag(0)
                    serverPage.tag(1)
                    printerPage.tag(2)
                    defaultsPage.tag(3)
                    finishPage.tag(4)
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
                    .tint(.primary)
                    .disabled(!stepValid)
            }
        }
        .padding()
    }

    private var stepValid: Bool {
        switch step {
        case 1: return settings.demoWanted ? true : (!settings.serverURL.isEmpty && !settings.apiToken.isEmpty)
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
                Text("Dein A1.\nÜberall im Griff.")
                    .font(.system(.largeTitle, design: .serif)).fontWeight(.bold)
                    .multilineTextAlignment(.center)
                Text("BambuController verbindet deinen Bambu Lab A1 mit deinem iPhone — zuhause wie unterwegs.")
                    .font(.body).foregroundColor(.secondary)
                    .font(.body).foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                VStack(spacing: 12) {
                    FeatureRow(icon: "server.rack", title: "Raspberry Pi als Brücke", text: "Der Pi spricht direkt mit deinem Drucker im Heimnetz (MQTT, TLS).")
                    FeatureRow(icon: "lock.shield.fill", title: "Weltweit & sicher", text: "Per Tailscale-VPN erreichst du den Pi von überall — ohne Portfreigaben.")
                    FeatureRow(icon: "gauge.with.dots.needle.33percent", title: "Live & Steuerung", text: "Temperaturen, Fortschritt, Pause/Stopp, Speed-Modi, Licht und Kamera.")
                }
                .padding(.horizontal)
                DataSplitCard()
                    .padding(.horizontal)
            }
        }
    }

    private var printerPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("2 · Drucker (am Drucker stehend ausfüllen)").font(.caption).fontWeight(.bold).foregroundColor(AppTheme.accent)
                Text("A1 mit dem Pi verbinden").font(.title2).fontWeight(.bold)
                HintText(text: "Geh mit dem Handy zum Drucker und tippe ab, was Display bzw. Aufkleber zeigen. Per „Weiter\" geht's auch ohne — nachholbar in den Einstellungen.")
                if settings.serverURL.isEmpty || settings.apiToken.isEmpty {
                    HintText(text: "Hinweis: Ohne Server-URL + Token (Schritt 1) kann ich noch nichts an den Pi schicken.")
                }
                Text("Drucker-IP (Heimnetz)").font(.subheadline).fontWeight(.semibold)
                TextField("z. B. 192.168.1.50", text: $printerHost)
                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.decimalPad)
                Text("Seriennummer").font(.subheadline).fontWeight(.semibold)
                TextField("z. B. 01S00A…", text: $printerSerial)
                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("LAN Access Code (8-stellig)").font(.subheadline).fontWeight(.semibold)
                TextField("z. B. 12345678", text: $printerCode)
                    .textFieldStyle(.roundedBorder).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Wo finde ich diese Daten?") { showWherePrinter = true }
                    .font(.footnote)
                    .sheet(isPresented: $showWherePrinter) {
                        HelpSheet(title: "Druckerdaten finden", lines: [
                            "1. Am A1-Display: Einstellungen → Netzwerk → IP-Adresse + Access Code.",
                            "2. Seriennummer: Aufkleber am Drucker oder auf der Verpackung.",
                            "3. Wichtig: Entwickler-/LAN-Modus am Drucker muss AN sein.",
                        ])
                    }
                Button {
                    sendPrinterConfig()
                } label: {
                    if printerSending { ProgressView().frame(maxWidth: .infinity) }
                    else { Text("An Pi senden & verbinden").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.borderedProminent).tint(.primary)
                .disabled(printerHost.isEmpty || printerSerial.isEmpty || printerCode.isEmpty || printerSending
                    || settings.serverURL.isEmpty || settings.apiToken.isEmpty)
                if let r = printerResult {
                    Text(r).font(.footnote).foregroundColor((printerOK ?? false) ? .green : .orange)
                }
            }.padding()
        }
        .onAppear { loadCurrentPrinterConfig() }
    }

    private var serverPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("1 · Server (Raspberry Pi)").font(.caption).fontWeight(.bold).foregroundColor(AppTheme.accent)
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
                        .touchTarget()
                        .accessibilityLabel(showToken ? "Token verbergen" : "Token anzeigen")
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
                .buttonStyle(.borderedProminent).tint(.primary)
                .disabled(settings.serverURL.isEmpty || settings.apiToken.isEmpty || testing)
                if let r = testResult {
                    Text(r).font(.footnote).foregroundColor(r.hasPrefix("✅") ? .green : .red)
                }
            }.padding()
        }
    }

    private var defaultsPage: some View {
        ScrollView {
            VStack(spacing: 6) {
                Text("3 · Deine Standards").font(.caption).fontWeight(.bold).foregroundColor(AppTheme.accent)
                Text("Womit druckst\ndu am meisten?")
                    .font(.system(.largeTitle, design: .serif)).fontWeight(.bold)
                    .multilineTextAlignment(.center)
                HintText(text: "Einfach am Lineal ziehen — die App schlägt diese Werte beim Druckstart vor.")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                VStack(spacing: 22) {
                    VStack(spacing: 2) {
                        Text("Düse").font(.headline)
                        RulerSlider(value: $settings.defaultNozzleTemp, range: 0...300, step: 5, unit: "°C", tint: .orange, presets: [190, 210, 230])
                    }
                    .onChange(of: settings.defaultNozzleTemp) { _, _ in settings.commit() }
                    VStack(spacing: 2) {
                        Text("Druckbett").font(.headline)
                        RulerSlider(value: $settings.defaultBedTemp, range: 0...100, step: 5, unit: "°C", tint: .red, presets: [50, 60, 70])
                    }
                    .onChange(of: settings.defaultBedTemp) { _, _ in settings.commit() }
                }
                .padding(.top, 8)
                Spacer(minLength: 20)
            }.padding()
        }
    }

    private var finishPage: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("4 · Los geht's").font(.caption).fontWeight(.bold).foregroundColor(AppTheme.accent)
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
        settings.commit()
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

    private func loadCurrentPrinterConfig() {
        Task {
            do {
                let cfg = try await APIService.shared.getPrinterConfig()
                if let h = cfg.printerHost, printerHost.isEmpty { printerHost = h }
                if let s = cfg.printerSerial, printerSerial.isEmpty { printerSerial = s }
                if cfg.printerConnected {
                    printerOK = true
                    printerResult = "✅ Drucker bereits verbunden."
                }
            } catch { /* still unconfigured — user types values */ }
        }
    }

    private func sendPrinterConfig() {
        settings.commit()
        printerSending = true; printerResult = nil; printerOK = nil
        let host = printerHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let serial = printerSerial.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = printerCode.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let res = try await APIService.shared.savePrinterConfig(host: host, serial: serial, code: code)
                printerOK = res.printerConnected
                printerResult = res.printerConnected
                    ? "✅ " + res.message
                    : "⚠️ " + res.message
            } catch {
                printerOK = false
                printerResult = "❌ \(error.localizedDescription)"
            }
            printerSending = false
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
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                    .fill(selected ? AppTheme.accent.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.cardRadius, style: .continuous)
                    .stroke(style: StrokeStyle(lineWidth: selected ? 2 : 1.2, dash: selected ? [] : [7, 5]))
                    .foregroundColor(selected ? AppTheme.accent : Color(.systemGray3))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)\(selected ? ", ausgewählt" : "")")
    }
}

/// Explains once where each credential lives — printer data stays on the Pi.
private struct DataSplitCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Wo liegt was?", systemImage: "folder.fill")
                .font(.headline)
            DataSplitRow(icon: "printer.fill", text: "Drucker-IP, Seriennummer & Access Code: **nur auf dem Pi** (fragt der Installer einmal ab).")
            DataSplitRow(icon: "iphone", text: "Hier in der App brauchst du **nur Server-URL + Token** vom Pi-Bildschirm.")
        }
        .padding().card()
    }
}

private struct DataSplitRow: View {
    let icon, text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundColor(AppTheme.accent).frame(width: 22)
            Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                .font(.footnote).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
