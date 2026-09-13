// SetupFlowView.swift - Ersteinrichtung für Nicht-Techniker.
//
// 0 Willkommen → 1 Pi suchen (1 Tap, kein Tippen) → 2 Drucker vorbereiten
// (3 Bildchen-Schritte) → 3 Drucker suchen (Pi scannt) → 4 Code + Seriennummer
// → 5 Fertig. Kurze Sätze, große Buttons, überall Retry.
import SwiftUI

struct SetupFlowView: View {
    @Binding var finished: Bool
    @State private var step = 0
    @StateObject private var discovery = PiDiscovery.shared
    @State private var settings = AppSettings.shared

    // Pi
    @State private var pairing = false
    @State private var pairError: String?
    // Drucker
    @State private var candidates: [PrinterCandidate] = []
    @State private var chosenIP: String?
    @State private var manualIP = ""
    @State private var scanning = false
    @State private var scanError: String?
    @State private var serial = ""
    @State private var code = ""
    @State private var connecting = false
    @State private var connectResult: String?
    @State private var connectOK = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: Double(step + 1), total: 6)
                    .progressViewStyle(LinearProgressViewStyle(tint: AppTheme.accent))
                    .padding(.horizontal).padding(.top, 8)
                TabView(selection: $step) {
                    welcome.tag(0)
                    piPage.tag(1)
                    printerPrepPage.tag(2)
                    printerScanPage.tag(3)
                    printerCodePage.tag(4)
                    donePage.tag(5)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: step)
                navBar
            }
            .navigationTitle("Einrichtung")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var navBar: some View {
        HStack {
            if step > 0 && step < 5 {
                Button("Zurück") { withAnimation { step -= 1 } }
                    .buttonStyle(.bordered)
                    .tint(AppTheme.accent)
            }
            Spacer()
            if step == 0 || step == 5 { EmptyView() }
            else if step < 4 {
                Button("Weiter") { withAnimation { step += 1 } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!stepValid)
                    .frame(maxWidth: 180)
            }
        }
        .padding()
    }

    private var stepValid: Bool {
        switch step {
        case 1: return !settings.serverURL.isEmpty && !settings.apiToken.isEmpty
        case 3: return !(chosenIP ?? "").isEmpty || !manualIP.isEmpty
        default: return true
        }
    }

    // MARK: - 0 Willkommen (Apple-seriös, mit Druckerbild)

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            if let ui = PrinterHeroImage.load() {
                Image(uiImage: ui)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 300, maxHeight: 260)
                    .accessibilityLabel("Bambu Lab A1")
            }
            Text("Bambu Lab A1 einrichten")
                .font(.system(.title, design: .default)).fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .padding(.top, 24)
            Text("Wir verbinden Drucker, Raspberry Pi und iPhone. Schritt für Schritt.")
                .font(.body).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32).padding(.top, 8)
            Spacer()
            Button("Weiter") { withAnimation { step = 1 } }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 20)
            Button("Demo ansehen") {
                settings.demoWanted = true; settings.demoMode = true
                settings.onboarded = true; settings.commit(); finished = true
            }
            .font(.footnote).foregroundColor(.secondary)
            .padding(.top, 12).padding(.bottom, 8)
        }
    }

    // MARK: - 1 Pi suchen (kein Tippen)

    private var piPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Dein Pi meldet sich von allein").font(.title2).fontWeight(.bold)
                Text("Gleiches WLAN wie der Pi. Dann erscheint er hier — antippen, fertig.")
                    .font(.subheadline).foregroundColor(.secondary)
                if discovery.pis.isEmpty {
                    HStack { Spacer()
                        VStack(spacing: 8) {
                            if discovery.searching { ProgressView("Suche läuft …") }
                            else { Text("Noch nichts gefunden.").foregroundColor(.secondary) }
                            Button("Erneut suchen") { discovery.start() }
                                .buttonStyle(.bordered)
                                .tint(AppTheme.accent)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 24)
                } else {
                    ForEach(discovery.pis) { pi in
                        Button { Task { await pair(pi) } } label: {
                            HStack {
                                Image(systemName: "server.rack").font(.title2).foregroundColor(AppTheme.accent)
                                VStack(alignment: .leading) {
                                    Text(pi.name).font(.headline).foregroundColor(.primary)
                                    Text(pi.paired ? "Bereits vergeben" : "Bereit — antippen")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                if pairing { ProgressView() }
                                else { Image(systemName: "chevron.right").foregroundColor(.secondary) }
                            }
                            .padding().card()
                        }
                        .buttonStyle(.plain)
                        .disabled(pairing)
                    }
                }
                if let e = pairError { Text(e).font(.footnote).foregroundColor(.red) }
                if !settings.serverURL.isEmpty {
                    Text("✅ Pi antwortet und nimmt Befehle an: \(settings.serverURL)").font(.footnote).foregroundColor(.green)
                } else {
                    Text("Tippe oben auf deinen Pi, um weiterzumachen.").font(.footnote).foregroundColor(.secondary)
                }
                HintText(text: "Pi unsichtbar? Gleiches WLAN prüfen (kein Gast-WLAN), 2 Minuten warten, erneut suchen.")
            }
            .padding()
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private func pair(_ pi: DiscoveredPi) async {
        pairing = true; pairError = nil
        defer { pairing = false }
        // 3 Versuche mit Pause — Remote darf nicht an einem Wackler scheitern
        var last: Error?
        for attempt in 1...3 {
            do {
                let claim = try await APIService.shared.claimPi(baseURL: pi.baseURL)
                settings.serverURL = pi.baseURL
                settings.apiToken = claim.apiToken
                settings.demoWanted = false
                settings.commit()
                // Pflicht-Check: Kann die App einen Befehl an den Pi schicken
                // und bekommt sie eine Antwort? (Token/Pi wirklich erreichbar?)
                do {
                    _ = try await APIService.shared.getPrinterConfig()
                } catch {
                    pairError = "Pi gefunden, antwortet aber nicht auf Befehle (\(error.localizedDescription)). Gleiches WLAN? Erneut suchen."
                    return
                }
                withAnimation { step = 2 }
                return
            } catch {
                // 403 = schon vergeben → NICHT erneut claimen
                if let e = error as? APIError, case .httpError(403, _) = e {
                    pairError = "Dieser Pi gehört schon zu einem Handy (Repair in den Einstellungen oder „sudo bambu repair“ auf dem Pi)."
                    return
                }
                last = error
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
            }
        }
        if let e = last as? APIError, case .httpError(403, _) = e {
            pairError = "Dieser Pi gehört schon zu einem Handy (Repair in den Einstellungen oder „sudo bambu repair“ auf dem Pi)."
        } else {
            pairError = "Klappt gerade nicht (\(last?.localizedDescription ?? "?")). Erneut versuchen."
        }
    }

    // MARK: - 2 Drucker vorbereiten (3 Mini-Schritte, wenig Text)

    private var printerPrepPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Am Drucker: 2 Schalter an").font(.title2).fontWeight(.bold)
                Text("Geh zum Drucker. Dauert 1 Minute.").font(.subheadline).foregroundColor(.secondary)
                PrepRow(n: "1", icon: "gear", text: "Zahnrad (oben rechts) → **WLAN**.")
                PrepRow(n: "2", icon: "wifi", text: "**LAN Only** einschalten. Code + IP merken.")
                PrepRow(n: "3", icon: "hammer", text: "Weiter unten **Developer Mode** einschalten.")
                HintText(text: "Code nur Nullen? Schalter aus und wieder an. Nach Updates prüfen, ob beide Schalter noch an sind.")
            }
            .padding()
        }
    }

    // MARK: - 3 Drucker suchen (Pi scannt)

    private var printerScanPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Drucker im Heimnetz finden").font(.title2).fontWeight(.bold)
                Text("Der Pi horcht, wer antwortet. Meist ist es genau einer.")
                    .font(.subheadline).foregroundColor(.secondary)
                if candidates.isEmpty && !scanning {
                    Button {
                        Task { await scan() }
                    } label: {
                        Text("Nach Drucker suchen").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                if scanning { HStack { Spacer(); ProgressView("Pi sucht im Heimnetz … (bis zu 20 s)"); Spacer() }.padding() }
                ForEach(candidates) { c in
                    Button {
                        chosenIP = c.ip; manualIP = ""
                    } label: {
                        HStack {
                            Image(systemName: "printer.fill").foregroundColor(AppTheme.accent)
                            Text(c.ip).font(.headline).foregroundColor(.primary).monospacedDigit()
                            Spacer()
                            if chosenIP == c.ip { Image(systemName: "checkmark.circle.fill").foregroundColor(AppTheme.accent) }
                        }
                        .padding().card()
                    }
                    .buttonStyle(.plain)
                }
                if let e = scanError { Text(e).font(.footnote).foregroundColor(.orange) }
                if !candidates.isEmpty || scanError != nil {
                    Text("Nicht dabei?").font(.subheadline).fontWeight(.semibold)
                    TextField("IP vom Display, z. B. 192.168.1.50", text: $manualIP)
                        .textFieldStyle(.roundedBorder).keyboardType(.decimalPad)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .onChange(of: manualIP) { _, v in if !v.isEmpty { chosenIP = nil } }
                }
            }
            .padding()
        }
    }

    private func scan() async {
        scanning = true; scanError = nil; candidates = []
        defer { scanning = false }
        do {
            let res = try await APIService.shared.scanPrinters()
            candidates = res.candidates
            if res.candidates.count == 1 { chosenIP = res.candidates[0].ip }
            if res.candidates.isEmpty {
                scanError = "Kein Drucker im Netz \(res.prefix) gefunden. Drucker an? Gleiches WLAN? LAN-/Entwicklermodus an (Schritt zurück)? Du kannst die IP auch von Hand eingeben."
            }
        } catch {
            scanError = "Suche fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    // MARK: - 4 Code + Serial (einzige Eingabe, groß)

    private var printerCodePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Fast geschafft").font(.title2).fontWeight(.bold)
                Text("Steht auf dem Drucker-Display bzw. Aufkleber. Danach verbindet der Pi von allein.")
                    .font(.subheadline).foregroundColor(.secondary)
                Text("IP-Adresse").font(.headline)
                Text(effectiveIP.isEmpty ? "—" : effectiveIP).font(.title3).monospacedDigit()
                Text("Access Code (8 Zahlen vom Display)").font(.headline)
                TextField("z. B. 12345678", text: $code)
                    .textFieldStyle(.roundedBorder).keyboardType(.numberPad)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .font(.title2)
                Text("Seriennummer (Aufkleber)").font(.headline)
                TextField("z. B. 01S00A…", text: $serial)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .font(.title3)
                Button {
                    Task { await connectPrinter() }
                } label: {
                    if connecting { ProgressView().frame(maxWidth: .infinity) }
                    else { Text("Verbinden").frame(maxWidth: .infinity) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(connecting || effectiveIP.isEmpty || code.count != 8 || serial.isEmpty)
                HintText(text: "Code hat immer genau 8 Zahlen.")
                if let r = connectResult {
                    Text(r).font(.footnote).foregroundColor(connectOK ? .green : .orange)
                }
            }
            .padding()
        }
    }

    private var effectiveIP: String {
        chosenIP ?? manualIP.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func connectPrinter() async {
        connecting = true; connectResult = nil; connectOK = false
        defer { connecting = false }
        // 2 Versuche: der Drucker braucht nach Modus-Wechsel manchmal einen Moment
        var last: String?
        for attempt in 1...2 {
            do {
                let res = try await APIService.shared.savePrinterConfig(
                    host: effectiveIP,
                    serial: serial.trimmingCharacters(in: .whitespacesAndNewlines),
                    code: code.trimmingCharacters(in: .whitespacesAndNewlines))
                connectOK = res.printerConnected
                connectResult = (res.printerConnected ? "✅ " : "⚠️ ") + res.message
                if res.printerConnected { withAnimation { step = 5 } }
                return
            } catch {
                if let api = error as? APIError, case .timeout = api {
                    last = "Der Pi antwortet nicht rechtzeitig (Drucker an? Gleiches WLAN? LAN-Modus + Entwicklermodus an? IP noch aktuell?). Einfach erneut tippen."
                } else {
                    last = error.localizedDescription
                }
                if attempt == 1 { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            }
        }
        connectResult = "❌ \(last ?? "Fehler"). Code + IP prüfen, LAN-Modus an?"
    }

    // MARK: - 5 Abschluss (sachlich, ohne Ausrufe)

    private var donePage: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 64, weight: .light))
                .foregroundColor(.secondary)
            Text("Drucker verbunden")
                .font(.system(.title, design: .default)).fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .padding(.top, 24)
            Text("Drucker, Raspberry Pi und iPhone sind eingerichtet.")
                .font(.body).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32).padding(.top, 8)
            Spacer()
            Button("Weiter") {
                settings.onboarded = true; settings.demoMode = false; settings.commit()
                finished = true
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 20).padding(.bottom, 8)
        }
    }
}

private struct PrepRow: View {
    let n, icon, text: String
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(AppTheme.accent.opacity(0.15)).frame(width: 44, height: 44)
                Text(n).font(.headline).foregroundColor(AppTheme.accent)
            }
            Image(systemName: icon).foregroundColor(.secondary).frame(width: 24)
            Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                .font(.body)
            Spacer()
        }
        .padding().card()
    }
}

#Preview { SetupFlowView(finished: .constant(false)) }
